import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-223 deliverable 1 — throttle-aware pin-label pipeline
//
// On-device, reverse geocoders THROTTLE aggressive drag bursts, and the
// pre-MYR-223 ladder degraded EVERY geocode failure straight to the neutral
// "Pinned location" — so a pin resting on a named road read neutral (the
// client's evidence). These tests pin the three-way outcome + the single-flight
// / supersede / backoff-retry pipeline that fixes it, and the invariant that the
// confirmed pickup COORDINATE is never blocked on the label.

// A labeler that returns a scripted sequence of outcomes (last repeats), and
// records the coordinates it was asked to resolve — a fake throttling geocoder.
@MainActor
private final class ScriptedLabeler: RidePinLabeling {
    var outcomes: [PinLabelResolution]
    private(set) var calls: [CLLocationCoordinate2D] = []
    init(_ outcomes: [PinLabelResolution]) { self.outcomes = outcomes }
    func resolve(for coordinate: CLLocationCoordinate2D) async -> PinLabelResolution {
        calls.append(coordinate)
        return outcomes[min(calls.count - 1, outcomes.count - 1)]
    }
}

@MainActor
final class ThrottleAwarePinLabelTests: XCTestCase {

    private let pin = CLLocationCoordinate2D(latitude: 33.0901, longitude: -96.8514)

    private func makeLiveState(pinLabeler: any RidePinLabeling) -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: SimulatedUserLocation(),
            liveVehicleLocator: nil,
            pinLabeler: pinLabeler,
            isLive: true
        )
        return SharedViewerState(seams: seams)
    }

    // MARK: failure classification (the throttle-vs-genuine table)

    func testThrottleAndTransientErrorsClassifyAsFailedRetry() {
        // MapKit's rate-limit signal + a server/unknown failure → retry.
        XCTAssertEqual(LivePinLabeler.classify(MKError(.loadingThrottled)), .failed)
        XCTAssertEqual(LivePinLabeler.classify(MKError(.serverFailure)), .failed)
        XCTAssertEqual(LivePinLabeler.classify(MKError(.unknown)), .failed)
        // CLGeocoder throttles rapid reverse-geocodes to a network error → retry.
        XCTAssertEqual(LivePinLabeler.classify(CLError(.network)), .failed)
    }

    func testGenuineNoResultClassifiesAsEmpty() {
        // An explicit "no placemark here" is genuine — retrying returns nothing.
        XCTAssertEqual(LivePinLabeler.classify(MKError(.placemarkNotFound)), .empty)
        XCTAssertEqual(LivePinLabeler.classify(CLError(.geocodeFoundNoResult)), .empty)
    }

    func testGeocodeFailureSurfacesAsFailedNotUnresolved() async {
        // The whole point of the three-way outcome: a throttle is `.failed`
        // (retryable), NOT `.unresolved` (which would degrade to neutral).
        let throttled = LivePinLabeler(resolve: { _ in .failed })
        let genuine = LivePinLabeler(resolve: { _ in .empty })
        // A geocoder that answers but the ladder rejects (bare city) → unresolved.
        let bareCity = LivePinLabeler(resolve: { _ in
            .success(.init(fields: .init(locality: "Frisco"), snappedLocation: nil))
        })
        let a = await throttled.resolve(for: pin)
        let b = await genuine.resolve(for: pin)
        let c = await bareCity.resolve(for: pin)
        XCTAssertEqual(a, .failed)
        XCTAssertEqual(b, .unresolved)
        XCTAssertEqual(c, .unresolved)
    }

    // MARK: the composed ladder retries on throttle rather than degrading

    func testBestResolutionRetriesOnThrottleRatherThanFallingToNearOrNeutral() {
        let poi = PickupPOI(name: "Grandscape", coordinate: CLLocationCoordinate2D(
            latitude: pin.latitude + 60 / 111_000.0, longitude: pin.longitude)) // ~60m → "near"
        // A throttled geocode with only a NEAR poi → retry (don't settle for
        // "Near X" while the real street may still resolve).
        XCTAssertEqual(
            LivePickupPointLabeler.bestResolution(pin: pin, pois: [poi], geocode: .failed),
            .failed)
        // …but a doorstep poi answers immediately — no retry needed.
        let doorstep = PickupPOI(name: "Starbucks", coordinate: CLLocationCoordinate2D(
            latitude: pin.latitude + 10 / 111_000.0, longitude: pin.longitude))
        XCTAssertEqual(
            LivePickupPointLabeler.bestResolution(pin: pin, pois: [doorstep], geocode: .failed),
            .resolved("Starbucks"))
        // A GENUINE unresolved geocode with a near poi → "Near X" (the fallback).
        XCTAssertEqual(
            LivePickupPointLabeler.bestResolution(pin: pin, pois: [poi], geocode: .unresolved),
            .resolved("Near Grandscape"))
        // Nothing near, unresolved geocode → neutral.
        XCTAssertEqual(
            LivePickupPointLabeler.bestResolution(pin: pin, pois: [], geocode: .unresolved),
            .unresolved)
    }

    // MARK: label-state transitions (resolving → resolved / resolving → retry → neutral)

    func testResolvingThenResolved() async {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.resolved("1200 Grandscape Blvd")]))
        state.pinDropCameraSettled(at: pin)
        // Synchronously (before the debounced task runs): in flight → "Finding…".
        XCTAssertEqual(state.pinLabelState, .resolving)
        XCTAssertEqual(state.pinDropLabel, SharedViewerState.pinResolvingLabel)
        // Then it resolves.
        await eventually { state.pinLabelState == .resolved("1200 Grandscape Blvd") }
        XCTAssertEqual(state.pinDropLabel, "1200 Grandscape Blvd")
    }

    func testResolvingWhenGenuinelyUnresolvedGoesNeutral() async {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.unresolved]))
        state.pinDropCameraSettled(at: pin)
        XCTAssertEqual(state.pinDropLabel, SharedViewerState.pinResolvingLabel)
        await eventually { state.pinLabelState == .neutral }
        XCTAssertEqual(state.pinDropLabel, SharedViewerState.pinNeutralLabel)
    }

    func testThrottleRetriesWhileFindingThenNeutralOnExhaustion() async {
        // Always throttled: the pipeline retries the full backoff schedule
        // (initial + 2 backoffs = 3 calls) staying "Finding…", then degrades to
        // neutral only once retries are exhausted — never a wrong street.
        let labeler = ScriptedLabeler([.failed])
        let state = makeLiveState(pinLabeler: labeler)
        state.pinDropCameraSettled(at: pin)
        XCTAssertEqual(state.pinDropLabel, SharedViewerState.pinResolvingLabel)
        // Mid-backoff it is still "Finding…", not neutral.
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(state.pinLabelState, .resolving, "still retrying, not degraded early")
        await eventually(timeout: 6) { state.pinLabelState == .neutral }
        XCTAssertEqual(labeler.calls.count, SharedViewerState.pinLabelRetryBackoffs.count + 1,
                       "one initial attempt plus one per backoff interval")
    }

    func testThrottleThenSuccessResolvesAfterBackoff() async {
        // Two throttles then a success: the pin lands on the street once the
        // rate limit clears, instead of the old immediate neutral.
        let labeler = ScriptedLabeler([.failed, .failed, .resolved("Legacy Dr")])
        let state = makeLiveState(pinLabeler: labeler)
        state.pinDropCameraSettled(at: pin)
        await eventually(timeout: 6) { state.pinLabelState == .resolved("Legacy Dr") }
        XCTAssertEqual(state.pinDropLabel, "Legacy Dr")
    }

    // MARK: single-flight + supersede

    func testNewerSettleSupersedesAndCancelsTheStaleResolution() async throws {
        // Two settles inside the debounce window: the first task is cancelled
        // before it ever calls the resolver — only the newer coordinate resolves.
        let labeler = ScriptedLabeler([.resolved("B St")])
        let state = makeLiveState(pinLabeler: labeler)
        let a = CLLocationCoordinate2D(latitude: 33.10, longitude: -96.90)
        let b = CLLocationCoordinate2D(latitude: 33.20, longitude: -96.70)
        state.pinDropCameraSettled(at: a)
        state.pinDropCameraSettled(at: b) // supersedes A while A is still debouncing
        await eventually { state.pinLabelState == .resolved("B St") }
        XCTAssertEqual(labeler.calls.count, 1, "single-flight: the superseded settle never fired")
        let firstCall = try XCTUnwrap(labeler.calls.first)
        XCTAssertEqual(firstCall.latitude, b.latitude, accuracy: 1e-9)
    }

    // MARK: coordinate is never blocked on the label

    func testConfirmedCoordinateNeverBlockedOnLabelState() async {
        // Even with a geocoder stuck throttling forever, the confirmed pickup
        // coordinate is the settled center IMMEDIATELY — send-time never waits
        // on the label (the glyph's MapProxy ground truth is authoritative).
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.failed]))
        let dragged = CLLocationCoordinate2D(latitude: 33.1234, longitude: -96.5678)
        state.pinDropCameraSettled(at: dragged)
        XCTAssertEqual(state.pinDropCoordinate.latitude, dragged.latitude, accuracy: 1e-9)
        XCTAssertEqual(state.pinDropCoordinate.longitude, dragged.longitude, accuracy: 1e-9)
        // Label is still resolving — coordinate is unaffected by it.
        XCTAssertEqual(state.pinLabelState, .resolving)
        XCTAssertEqual(state.pinDropCoordinate.latitude, dragged.latitude, accuracy: 1e-9)
    }

    // MARK: staleness guard interplay — keep a valid nearby street, don't flicker

    func testValidNearbyStreetIsKeptWhileReResolvingButFarDragShowsFinding() async {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.resolved("Grandscape Blvd")]))
        state.pinDropCameraSettled(at: pin)
        await eventually { state.pinLabelState == .resolved("Grandscape Blvd") }

        // A tiny nudge (<40m) keeps the valid street on screen — no flicker to
        // "Finding…".
        let near = CLLocationCoordinate2D(latitude: pin.latitude + 10 / 111_000.0, longitude: pin.longitude)
        state.pinDropCameraSettled(at: near)
        XCTAssertEqual(state.pinLabelState, .resolved("Grandscape Blvd"),
                       "a within-staleness settle keeps the valid street while re-resolving")

        // A far drag (>40m) drops the now-stale street and shows the in-flight
        // label — never a confidently-wrong street, never (yet) neutral.
        let far = CLLocationCoordinate2D(latitude: pin.latitude + 500 / 111_000.0, longitude: pin.longitude)
        state.pinDropCameraSettled(at: far)
        XCTAssertEqual(state.pinLabelState, .resolving)
        XCTAssertEqual(state.pinDropLabel, SharedViewerState.pinResolvingLabel)
    }

    // MARK: -

    private func eventually(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never became true")
    }
}
