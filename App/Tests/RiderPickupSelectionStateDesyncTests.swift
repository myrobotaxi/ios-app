import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-445 — four state-desync defects in the MYR-379 pickup field
//
// The client, r-build `202608022357`, verbatim: *"the current location is stuck
// as a static placeholder, so I have to type over it. It doesn't disappear when
// selecting on it. Then if i type and search and select new pick up point it
// sets, but if I go backwards back to that search step and change the pick up
// point, current location shows as the placeholder again even though its not
// actually set and if I select current location or any other pick up address it
// doesn't actually set it and is stuck on the first one and doesn't let me fine
// tune the pick up, the map route polyline is also stuck bc the pickup point did
// not update."*
//
// FOUR DEFECTS, AND THEY ARE NOT FOUR BUGS. Two of them are one string collision
// and two of them are one missing write, which is why the report reads as a
// cascade rather than as a list:
//
//  1+2. `SharedViewerState.confirmedPickupLabel(for: .resolving)` persisted
//       `pickupFallbackLabel` — **the untouched default's own name** — onto a
//       committed pickup. MYR-239 chose that string when the pickup row was a
//       static `Text` and the alternative was a stuck "Finding address…";
//       MYR-379 then made the same string the FIELD's default rendering. So a
//       rider who confirmed a kerb while the reverse geocode was still in flight
//       (the ordinary case on a throttled device) came back to a field whose text
//       was literally "Current location" — indistinguishable from the default
//       (defect 2), and, being real text rather than the empty field's overlay,
//       something they had to type OVER (defect 1).
//  3+4. `clearPickup()` — the one control that expresses "Current location" as a
//       CHOICE — cleared `draftPickup` and `pinDropSeed` and left
//       `previewPickupAnchor` on the abandoned pickup. Every consumer reads the
//       anchor as its "current location" rung, so the choice resolved to the OLD
//       place (defect 3), the route cache was never re-keyed with a new pair, and
//       the polyline stayed where it was for the rest of the session (defect 4).
//
// THE PURE SUITE PROVES THE RULES; `RiderPickupReselectionUITests` proves the
// screen consults them (MYR-387 defect 2 / MYR-369's `VehicleRideShare.display`,
// the standing reason this repo does not accept a green unit suite as evidence
// that a surface works).

/// A device fix that can MOVE, so the anti-jitter guard has something to resist.
private final class DesyncUserLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    init(coordinate: CLLocationCoordinate2D?) { self.coordinate = coordinate }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { true }
    func start() {}
    func stop() {}
    func refresh() {}
}

/// A labeler that never answers — i.e. a pin confirmed while its street is still
/// resolving, which is the state defect 2 is entirely about.
@MainActor
private final class NeverAnsweringLabeler: RidePinLabeling {
    func resolve(for coordinate: CLLocationCoordinate2D) async -> PinLabelResolution {
        try? await Task.sleep(for: .seconds(60))
        return .failed
    }
}

/// A 3-point provider that counts calls — `RideRouteTests`' own stub, local so
/// the two files cannot drift into sharing a fixture.
private actor CountingRouteProvider: RideRouteProvider {
    private(set) var callCount = 0
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        callCount += 1
        let mid = CLLocationCoordinate2D(latitude: (from.latitude + to.latitude) / 2,
                                         longitude: (from.longitude + to.longitude) / 2)
        return [from, mid, to]
    }
    func count() -> Int { callCount }
}

@MainActor
final class RiderPickupSelectionStateDesyncTests: XCTestCase {

    /// The rider's own feet.
    private static let deviceFix = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    /// The FIRST pickup they type, and the kerb they drag to once there.
    private static let placeA = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    private static let kerbA = CLLocationCoordinate2D(latitude: 37.7961, longitude: -122.3944)
    /// The SECOND pickup — "any other pick up address".
    private static let placeB = CLLocationCoordinate2D(latitude: 37.8010, longitude: -122.4100)
    private static let kerbB = CLLocationCoordinate2D(latitude: 37.8015, longitude: -122.4110)
    private static let destination = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790)

    private func place(_ id: String, _ label: String, _ c: CLLocationCoordinate2D) -> MyRoboTaxi.RidePlace {
        MyRoboTaxi.RidePlace(id: id, label: label, subtitle: nil, miles: 0, minutes: 0, icon: "mappin", coordinate: c)
    }

    private func makeLiveState(
        fix: CLLocationCoordinate2D? = RiderPickupSelectionStateDesyncTests.deviceFix
    ) -> (SharedViewerState, DesyncUserLocation) {
        let location = DesyncUserLocation(coordinate: fix)
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: location,
            liveVehicleLocator: nil,
            pinLabeler: NeverAnsweringLabeler(),
            isLive: true
        )
        return (SharedViewerState(seams: seams), location)
    }

    private func assertSame(
        _ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D,
        _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let coordinate = lhs else {
            return XCTFail("\(what): expected a coordinate, got nil", file: file, line: line)
        }
        XCTAssertEqual(coordinate.latitude, rhs.latitude, accuracy: 1e-9, "\(what): lat", file: file, line: line)
        XCTAssertEqual(coordinate.longitude, rhs.longitude, accuracy: 1e-9, "\(what): lng", file: file, line: line)
    }

    /// The client's own sequence up to "it sets": choose a destination, type a
    /// pickup, chain into the pin-drop, drag to the kerb, confirm, land back on
    /// search. Returns the state ready for the half of his report that fails.
    private func riderWithACommittedPickup() -> (SharedViewerState, DesyncUserLocation) {
        let (state, location) = makeLiveState()
        state.enterSearchFromIdle()
        state.chooseDestination(place("sfo", "SFO · Terminal 2", Self.destination))
        state.selectPickup(place("ferry", "Ferry Building", Self.placeA))
        state.enterPinDrop()
        state.pinDropCameraSettled(at: Self.kerbA)
        state.confirmPickup()
        state.sheetPhase = .search
        return (state, location)
    }

    // MARK: - Defect 1 — focusing the field must not leave a default to type over

    /// The client's first sentence. Focus is what tells the two apart: the
    /// default may never be on screen at the moment the rider is about to type.
    func testTheDefaultIsNeverDrawnWhileTheFieldHoldsFirstResponder() {
        XCTAssertTrue(
            RidePickupFieldFocus.showsDefaultOverlay(text: "", isFocused: false),
            "an untouched, unfocused field still reads 'Current location' — MYR-379 unchanged"
        )
        XCTAssertFalse(
            RidePickupFieldFocus.showsDefaultOverlay(text: "", isFocused: true),
            "*\"It doesn't disappear when selecting on it\"* — now it does"
        )
        XCTAssertFalse(
            RidePickupFieldFocus.showsDefaultOverlay(text: "Ferry Building", isFocused: false),
            "and it is never drawn over real text, focused or not"
        )
    }

    /// *"so I have to type over it"* — typing must REPLACE a committed pickup,
    /// not append to it.
    func testFocusingAFieldThatHoldsAPickupClearsItSoTypingReplaces() {
        XCTAssertEqual(RidePickupFieldFocus.textOnFocusGained(current: "Pinned location"), "")
        XCTAssertEqual(RidePickupFieldFocus.textOnFocusGained(current: "Ferry Building"), "")
        XCTAssertEqual(RidePickupFieldFocus.textOnFocusGained(current: ""), "",
                       "an already-empty field is unchanged")
    }

    /// The clear is an EDITING affordance, never an erasure: a rider who taps in
    /// and taps away again has changed nothing, so the field re-seeds from the
    /// draft exactly as arrival does (MYR-389). A query left mid-typing is
    /// THEIRS and is kept.
    func testBlurringWithoutAChoiceRestoresTheDraftAndKeepsAQueryInFlight() {
        XCTAssertEqual(
            RidePickupFieldFocus.textOnFocusLost(current: "", draftLabel: "Pinned location"),
            "Pinned location",
            "the mirror re-seeds itself rather than claiming the pickup was removed"
        )
        XCTAssertEqual(
            RidePickupFieldFocus.textOnFocusLost(current: "", draftLabel: nil), "",
            "with no pickup set there is nothing to restore — the default comes back"
        )
        XCTAssertEqual(
            RidePickupFieldFocus.textOnFocusLost(current: "fer", draftLabel: "Pinned location"), "fer",
            "a query in flight is not ours to discard"
        )
    }

    /// The clear (`xmark`) is the ONE control that says "current location" as a
    /// choice, so it has to survive the focus clear above — keyed on the text
    /// alone it vanished at the instant the rider focused the field, which is the
    /// far half of *"if I select current location … it doesn't actually set it"*.
    func testTheClearAffordanceSurvivesTheFocusClearAndIsStillAbsentByDefault() {
        XCTAssertTrue(
            RidePickupFieldFocus.showsClearAffordance(text: "", hasDraftPickup: true),
            "focused-and-emptied over a SET pickup still offers the way back to the default"
        )
        XCTAssertTrue(RidePickupFieldFocus.showsClearAffordance(text: "fer", hasDraftPickup: false))
        XCTAssertFalse(
            RidePickupFieldFocus.showsClearAffordance(text: "", hasDraftPickup: false),
            "an untouched search offers nothing at all — byte-identical to before MYR-445"
        )
    }

    // MARK: - Defect 2 — a SET pickup must never wear the default's name

    /// The defect, at the exact line it lived on. A pin confirmed while its
    /// street is still resolving used to persist `pickupFallbackLabel`, so the
    /// field's mirror was faithfully rendering a label that says "nothing is set".
    func testAPickupConfirmedMidResolutionIsNeverNamedAfterTheDefault() {
        let (state, _) = riderWithACommittedPickup()

        XCTAssertNotNil(state.draftPickup, "the pin is committed")
        XCTAssertEqual(
            state.draftPickup?.label, SharedViewerState.pinNeutralLabel,
            "an unresolved kerb says it is a pinned spot"
        )
        XCTAssertNotEqual(
            state.draftPickup?.label, SharedViewerState.pickupFallbackLabel,
            "*\"current location shows as the placeholder again even though its not actually set\"*"
        )
        // MYR-239's own invariant, restated here so this fix cannot undo it.
        XCTAssertNotEqual(state.draftPickup?.label, SharedViewerState.pinResolvingLabel)
    }

    /// Defect 2 proper: the mirror's SOURCE survives the round trip. The rider
    /// leaves search for Review and comes back — the draft still holds the kerb,
    /// and the text the field re-seeds from still names it.
    func testReEnteringSearchStillFindsTheSetPickupInTheDraft() {
        let (state, _) = riderWithACommittedPickup()
        let committed = state.draftPickup

        state.enterReview()
        XCTAssertEqual(state.sheetPhase, .review)
        state.sheetPhase = .search // "I go backwards back to that search step"

        XCTAssertNotNil(state.draftPickup, "the pickup outlives the round trip")
        assertSame(state.draftPickup?.coordinate, Self.kerbA, "the confirmed kerb")
        XCTAssertEqual(state.draftPickup?.label, committed?.label)
        XCTAssertNotEqual(
            state.draftPickup?.label, SharedViewerState.pickupFallbackLabel,
            "so the field re-seeded from it cannot read as the untouched default"
        )
    }

    // MARK: - Defect 3 — an EXPLICIT choice always re-anchors

    /// *"if I select … any other pick up address"*. A second searched pickup
    /// re-anchors and re-seeds the pin-drop, and the kerb confirmed there is the
    /// one that ends up in the draft.
    func testReSelectingADifferentPickupAfterTheFirstOneTakes() {
        let (state, _) = riderWithACommittedPickup()

        state.selectPickup(place("union", "Union Square", Self.placeB))
        assertSame(state.previewPickupAnchor, Self.placeB, "the explicit re-choice re-anchored")
        assertSame(state.pinDropSeed, Self.placeB, "and re-seeded the pin-drop")
        assertSame(state.pinDropEntryCoordinate, Self.placeB, "which is where fine-tuning resumes")

        state.enterPinDrop()
        state.pinDropCameraSettled(at: Self.kerbB)
        state.confirmPickup()

        assertSame(state.draftPickup?.coordinate, Self.kerbB, "the SECOND kerb is the pickup")
        XCTAssertNotEqual(
            state.draftPickup?.coordinate.latitude, Self.kerbA.latitude,
            "*\"stuck on the first one\"* — it is not"
        )
    }

    /// **THE DEFECT.** *"if I select current location … it doesn't actually set
    /// it and is stuck on the first one."* Choosing the default is a CHOICE, so
    /// it has to move the anchor every consumer reads it through.
    func testExplicitlyChoosingCurrentLocationReAnchorsToTheLiveFix() {
        let (state, _) = riderWithACommittedPickup()
        assertSame(state.previewPickupAnchor, Self.placeA, "precondition: anchored on the first choice")

        state.clearPickup()

        XCTAssertNil(state.draftPickup, "the pickup is back to the implicit default")
        XCTAssertNil(state.pinDropSeed, "and the abandoned chain's seed went with it")
        assertSame(
            state.previewPickupAnchor, Self.deviceFix,
            "a deliberate return to the default is a choice, and it re-anchors to the rider's own feet"
        )
        assertSame(
            state.pickupETARiderAnchor, Self.deviceFix,
            "so every downstream consumer measures from where the rider actually is"
        )
    }

    /// The nil-guard is right for GPS and must stay right for GPS. Repeated
    /// destination choices under a MOVING fix may not walk the anchor — MYR-237's
    /// device trace is the whole reason that guard exists.
    func testGPSJitterStillCannotMoveTheAnchor() {
        let (state, location) = makeLiveState()
        state.enterSearchFromIdle()
        state.chooseDestination(place("sfo", "SFO", Self.destination))
        assertSame(state.previewPickupAnchor, Self.deviceFix, "anchored once, on the first choice")

        for step in 1...20 {
            location.coordinate = CLLocationCoordinate2D(
                latitude: Self.deviceFix.latitude + Double(step) * 0.00002,
                longitude: Self.deviceFix.longitude + Double(step) * 0.00002
            )
            state.chooseDestination(place("sfo", "SFO", Self.destination))
        }

        assertSame(
            state.previewPickupAnchor, Self.deviceFix,
            "twenty fixes later the anchor has not moved a metre"
        )
    }

    /// And the two writers do not collapse into one. An explicit choice must
    /// outrank an anchor that is already set (the guard-swallow the issue named);
    /// a destination choice must not.
    func testAnExplicitChoiceOverwritesAnAnchorThatADestinationChoiceWouldNot() {
        let (state, location) = makeLiveState()
        state.enterSearchFromIdle()
        state.chooseDestination(place("sfo", "SFO", Self.destination))
        assertSame(state.previewPickupAnchor, Self.deviceFix, "the nil-guarded writer wrote once")

        // The rider walks a block. A second destination choice must NOT follow.
        location.coordinate = Self.placeB
        state.chooseDestination(place("oak", "Oakland", Self.destination))
        assertSame(state.previewPickupAnchor, Self.deviceFix, "still the first fix")

        // A TAP, however, always lands.
        state.selectPickup(place("ferry", "Ferry Building", Self.placeA))
        assertSame(state.previewPickupAnchor, Self.placeA, "an explicit choice is never swallowed")
    }

    // MARK: - Defect 4 — the polyline re-keys off the moved anchor

    /// The ladder the route preview is keyed on, stated once
    /// (`SharedViewerScreen.searchPreviewPickup` consults exactly this).
    func testThePreviewPickupLadderPrefersTheDraftAndFallsBackToTheAnchor() {
        assertSame(
            RidePreviewPickup.resolve(requestPickup: nil, draftPickup: Self.kerbA, anchor: Self.placeB),
            Self.kerbA, "a confirmed pickup outranks the anchor"
        )
        assertSame(
            RidePreviewPickup.resolve(requestPickup: nil, draftPickup: nil, anchor: Self.deviceFix),
            Self.deviceFix, "'current location' is the ANCHOR — a written fix, never a read one"
        )
        assertSame(
            RidePreviewPickup.resolve(requestPickup: Self.placeB, draftPickup: Self.kerbA, anchor: Self.deviceFix),
            Self.placeB, "a submitted ride's own pickup outranks the draft"
        )
        XCTAssertNil(RidePreviewPickup.resolve(requestPickup: nil, draftPickup: nil, anchor: nil))
    }

    /// End to end on the state: the coordinate the map keys its route from moves
    /// on BOTH kinds of re-choice. Before the fix the second one did not move at
    /// all, which is why *"the map route polyline is also stuck"*.
    func testTheRouteKeyingCoordinateMovesOnEveryExplicitReChoice() {
        let (state, _) = riderWithACommittedPickup()

        func previewPickup() -> CLLocationCoordinate2D? {
            RidePreviewPickup.resolve(
                requestPickup: nil,
                draftPickup: state.draftPickup?.coordinate,
                anchor: state.previewPickupAnchor
            )
        }

        assertSame(previewPickup(), Self.kerbA, "the first pickup keys the route")

        state.selectPickup(place("union", "Union Square", Self.placeB))
        state.enterPinDrop()
        state.pinDropCameraSettled(at: Self.kerbB)
        state.confirmPickup()
        assertSame(previewPickup(), Self.kerbB, "a different address re-keys it")

        state.clearPickup()
        assertSame(previewPickup(), Self.deviceFix, "and so does choosing current location")
    }

    /// The second half of defect 4, and it is its own bug: even once the pair
    /// genuinely changes, leg 2 used to keep serving the PREVIOUS pickup's road
    /// geometry until MKDirections answered. `ensureLeg1`'s header has claimed
    /// since MYR-293 that leg 2 "already had" this guard; it did not.
    func testANewPickupDropsTheCachedPolylineImmediatelyRatherThanServingTheOldOne() async {
        let provider = CountingRouteProvider()
        let store = RideRouteStore(provider: provider)

        store.ensureLeg2(pickup: Self.kerbA, destination: Self.destination)
        await eventually { store.leg2.count == 3 }
        assertSame(store.leg2.first, Self.kerbA, "the route starts at the first pickup")

        // The rider re-chooses. SYNCHRONOUSLY — before the new fetch can land —
        // there must be nothing left of the old route to draw.
        store.ensureLeg2(pickup: Self.kerbB, destination: Self.destination)
        XCTAssertTrue(
            store.leg2.isEmpty,
            "the previous pickup's polyline is dropped the moment the pair changes"
        )

        await eventually { store.leg2.count == 3 }
        assertSame(store.leg2.first, Self.kerbB, "and the new one etches from the new pickup")
    }

    /// The converse, which is what keeps the drop from becoming a flicker: the
    /// SAME pair is still fetched exactly once and its polyline is never dropped.
    func testTheSamePairIsStillCachedAndNeverDropped() async {
        let provider = CountingRouteProvider()
        let store = RideRouteStore(provider: provider)

        store.ensureLeg2(pickup: Self.kerbA, destination: Self.destination)
        await eventually { store.leg2.count == 3 }

        store.ensureLeg2(pickup: Self.kerbA, destination: Self.destination)
        XCTAssertEqual(store.leg2.count, 3, "a repeat ask for the same pair draws through, uninterrupted")
        let calls = await provider.count()
        XCTAssertEqual(calls, 1, "and asks the provider nothing")
    }

    // MARK: - Must not regress: the untouched default, and the fine-tune chain

    /// The guarantee that makes MYR-379 safe to ship, re-asserted after MYR-445
    /// touched three of its files: a rider who never goes near the pickup row is
    /// on exactly the pre-MYR-379 path.
    func testTheNeverTouchedPickupDefaultPathIsUnchanged() {
        let (state, _) = makeLiveState()
        state.enterSearchFromIdle()

        XCTAssertNil(state.draftPickup, "'Current location' is still what nil MEANS")
        XCTAssertNil(state.pinDropSeed)
        XCTAssertTrue(RidePickupFieldFocus.showsDefaultOverlay(text: "", isFocused: false))
        XCTAssertFalse(RidePickupFieldFocus.showsClearAffordance(text: "", hasDraftPickup: false))

        // The destination still routes through the pin-drop, seated on the fix.
        state.selectDestination(place("sfo", "SFO", Self.destination))
        XCTAssertEqual(state.sheetPhase, .pinDrop(returnTo: .review))
        assertSame(state.pinDropEntryCoordinate, Self.deviceFix, "the entry ladder's rung 3")
        assertSame(state.previewPickupAnchor, Self.deviceFix, "anchored once, by the nil-guarded writer")
    }

    /// The client's explicit complaint — *"doesn't let me fine tune the pick
    /// up"* — after each of the two re-choices. Fine-tuning resumes at the place
    /// the rider named, and after a return to the default at their own feet.
    func testFineTuningIsReachableAfterEveryReChoice() {
        let (state, _) = riderWithACommittedPickup()

        // (a) The "On map" capsule over a committed pickup: no seed, so the
        // ladder resumes at the kerb rather than throwing it away.
        state.sheetPhase = .pinDrop(returnTo: .search)
        state.enterPinDrop()
        assertSame(state.pinDropEntryCoordinate, Self.kerbA, "resumes at the confirmed pickup")
        state.returnFromPinDropToSearch()

        // (b) After choosing a different address.
        state.selectPickup(place("union", "Union Square", Self.placeB))
        state.enterPinDrop()
        assertSame(state.pinDropEntryCoordinate, Self.placeB, "resumes at the newly named place")
        state.pinDropCameraSettled(at: Self.kerbB)
        state.confirmPickup()

        // (c) After choosing current location.
        state.clearPickup()
        state.sheetPhase = .pinDrop(returnTo: .search)
        state.enterPinDrop()
        assertSame(
            state.pinDropEntryCoordinate, Self.deviceFix,
            "and after a return to the default, at the rider's own feet"
        )
    }

    /// MYR-389's list is still the ONE definition of a draft, and MYR-445 added a
    /// write to a field it already owns — so the reset must still clear it.
    func testTheDraftResetStillForgetsEverythingThisIssueTouches() {
        let (state, _) = riderWithACommittedPickup()
        state.selectPickup(place("union", "Union Square", Self.placeB))

        state.resetDraftToIdle()

        XCTAssertNil(state.draftPickup)
        XCTAssertNil(state.pinDropSeed)
        XCTAssertNil(state.previewPickupAnchor, "MYR-389's own finding, unchanged by the new writer")
        XCTAssertNil(state.draftDestination)
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
