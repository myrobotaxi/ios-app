import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-239 defect 1 — confirmed-pickup label (never a stuck transient)
//
// Client device QA (IMG_2192/2193/2194): after search → pick destination →
// pin-drop (confirm pickup) → review → back to Search, the pickup row read
// "Finding address…" forever — the MYR-223 pin-drop labeler's in-flight
// transient had been baked into `draftPickup.label` at confirm time, with
// nothing left to finish it. These tests pin the deterministic confirm behavior:
// the transient is NEVER persisted; a pin confirmed mid-resolution takes a calm
// placeholder and ONE bounded re-resolution upgrades it to the real street (or
// leaves the placeholder), and sim stays pixel-identical.
//
// ⚠️ MYR-445 DEFECT 2 CHANGED WHICH PLACEHOLDER, AND ONLY THAT. MYR-239 chose
// `pickupFallbackLabel` ("Current location") because it matched what the Search
// pickup row showed with NO pickup — a virtue when that row was a static `Text`.
// MYR-379 then made that string the FIELD's default rendering, so a genuinely
// committed kerb came back reading exactly like the untouched default: the
// client's *"current location shows as the placeholder again even though its not
// actually set"*. It is `pinNeutralLabel` ("Pinned location") now. MYR-239's
// invariant — never persist the "Finding address…" transient, always kick the
// bounded re-resolution — is asserted unchanged below, and the STRONGER rule that
// no confirmed pickup may ever wear the default's name is asserted with it.

// A labeler returning a scripted sequence of outcomes (last repeats).
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
final class ConfirmedPickupLabelTests: XCTestCase {

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

    private func makeSimState() -> SharedViewerState {
        SharedViewerState() // simulated seams
    }

    // MARK: pure state machine

    func testConfirmedPickupLabelIsNeverTheTransient() {
        // The whole defect: `.resolving` (the "Finding address…" transient) must
        // resolve to the calm fallback for persistence — never the transient.
        XCTAssertEqual(SharedViewerState.confirmedPickupLabel(for: .resolving),
                       SharedViewerState.pinNeutralLabel)
        XCTAssertNotEqual(SharedViewerState.confirmedPickupLabel(for: .resolving),
                          SharedViewerState.pinResolvingLabel)
        // MYR-445 — and never the DEFAULT's own name, in any state. Stated over
        // every label state rather than over the one case that regressed, so a
        // state added later has to answer the same question.
        let everyLabelState: [SharedViewerState.PinLabelDisplayState] = [
            .resolving, .neutral, .resolved("Legacy Dr")
        ]
        for labelState in everyLabelState {
            XCTAssertNotEqual(
                SharedViewerState.confirmedPickupLabel(for: labelState),
                SharedViewerState.pickupFallbackLabel,
                "a CONFIRMED pickup may never wear the untouched default's name (\(labelState))"
            )
        }
        // A resolved street persists as-is; a genuine neutral keeps "Pinned location".
        XCTAssertEqual(SharedViewerState.confirmedPickupLabel(for: .resolved("Legacy Dr")), "Legacy Dr")
        XCTAssertEqual(SharedViewerState.confirmedPickupLabel(for: .neutral),
                       SharedViewerState.pinNeutralLabel)
    }

    // MARK: confirm while still resolving

    func testConfirmWhileResolvingPersistsFallbackNotTransient() {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.failed]))
        state.pinDropCameraSettled(at: pin)
        XCTAssertEqual(state.pinLabelState, .resolving) // in-flight, synchronously
        state.confirmPickup()
        // The persisted pickup carries the calm placeholder, NEVER "Finding
        // address…" — and never the untouched default's name (MYR-445).
        XCTAssertEqual(state.draftPickup?.label, SharedViewerState.pinNeutralLabel)
        XCTAssertNotEqual(state.draftPickup?.label, SharedViewerState.pinResolvingLabel)
        // Coordinate is the authoritative settled center regardless of the label.
        XCTAssertEqual(state.draftPickup?.coordinate.latitude ?? .nan, pin.latitude, accuracy: 1e-9)
    }

    func testConfirmWhileResolvingUpgradesToStreetWhenResolutionLands() async {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.resolved("Legacy Dr")]))
        state.pinDropCameraSettled(at: pin)
        XCTAssertEqual(state.pinLabelState, .resolving)
        state.confirmPickup()
        XCTAssertEqual(state.draftPickup?.label, SharedViewerState.pinNeutralLabel) // placeholder first
        // The bounded re-resolution upgrades the confirmed pickup's label.
        await eventually { state.draftPickup?.label == "Legacy Dr" }
        XCTAssertEqual(state.draftPickup?.coordinate.latitude ?? .nan, pin.latitude, accuracy: 1e-9)
    }

    func testConfirmWhileResolvingThenThrottleThenSuccessUpgrades() async {
        // Two throttles then a street: the bounded ladder recovers the burst-
        // throttle instead of leaving the fallback (mirrors the pin-drop ladder).
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.failed, .failed, .resolved("Grandscape Blvd")]))
        state.pinDropCameraSettled(at: pin)
        state.confirmPickup()
        await eventually(timeout: 6) { state.draftPickup?.label == "Grandscape Blvd" }
    }

    func testConfirmWhileResolvingKeepsFallbackOnGenuineNoResult() async {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.unresolved]))
        state.pinDropCameraSettled(at: pin)
        state.confirmPickup()
        // A genuine no-result keeps the calm placeholder — never a stuck transient.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(state.draftPickup?.label, SharedViewerState.pinNeutralLabel)
    }

    func testConfirmWhileResolvingFallsBackAfterRetriesExhausted() async {
        // Always throttled: the bounded re-resolution gives up to the fallback,
        // NOT a permanent "Finding address…".
        let labeler = ScriptedLabeler([.failed])
        let state = makeLiveState(pinLabeler: labeler)
        state.pinDropCameraSettled(at: pin)
        state.confirmPickup()
        await eventually(timeout: 6) {
            labeler.calls.count >= SharedViewerState.pinLabelRetryBackoffs.count + 1
        }
        XCTAssertEqual(state.draftPickup?.label, SharedViewerState.pinNeutralLabel)
        XCTAssertNotEqual(state.draftPickup?.label, SharedViewerState.pinResolvingLabel)
    }

    // MARK: confirm after the street already resolved

    func testConfirmAfterResolvedPersistsStreetImmediately() async {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.resolved("Grandscape Blvd")]))
        state.pinDropCameraSettled(at: pin)
        await eventually { state.pinLabelState == .resolved("Grandscape Blvd") }
        state.confirmPickup()
        XCTAssertEqual(state.draftPickup?.label, "Grandscape Blvd") // synchronously, no re-kick needed
    }

    // MARK: sim stays pixel-identical

    func testSimConfirmKeepsFixtureLabel() {
        let state = makeSimState()
        state.sheetPhase = .pinDrop(returnTo: .review)
        state.enterPinDrop() // sets pinLabelState = .resolving, but sim ignores it
        state.confirmPickup()
        // Sim persists the fixture pin label verbatim — never the fallback/transient.
        XCTAssertEqual(state.draftPickup?.label, RideRequestFixtures.pinSpots[0])
    }

    // MARK: reset cancels the re-resolution

    func testResetToIdleClearsConfirmedPickup() {
        let state = makeLiveState(pinLabeler: ScriptedLabeler([.failed]))
        state.pinDropCameraSettled(at: pin)
        state.confirmPickup()
        state.resetDraftToIdle()
        XCTAssertNil(state.draftPickup)
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
