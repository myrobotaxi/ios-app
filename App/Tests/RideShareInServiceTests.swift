import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-358 — the ride-share toggle while the car is IN SERVICE
//
// Client direction: while a car is in service the toggle renders OFF and
// non-interactive, with its own caption. A car in a service bay cannot serve a
// ride — the server already refuses creates and accepts against it (§7.8) — so an
// owner's row still showing "Riders can request this car" is the last surface in
// the system telling them something untrue.
//
// THE SEMANTICS THAT MATTER MORE THAN THE PIXELS, and the reason this is a
// derivation rather than the obvious "just write false when it enters service":
//
//   • THE STORED PREFERENCE IS NEVER TOUCHED. No PUT fires on a service
//     transition, in either direction. The owner's standing instruction survives
//     the visit and renders again the moment it ends — they do not have to notice
//     that the app changed their setting and change it back.
//   • NO NEW WRITE PATH MEANS NO NEW REVERT HAZARD. A write fired by a status
//     change rather than by a finger would race the same reads MYR-351 exists to
//     fix, on a path nobody is watching. Deriving costs nothing.
//
// And it composes with MYR-351 rather than fighting it: the STORED value still
// arrives via `VehicleRideShare.resolvedEnabled`, so the executor's committed
// value still outranks a stale snapshot underneath the derivation. Test 5 pins
// that ordering, because an implementation that substituted its own value at the
// resolver level would hide the owner's flip for a whole visit and then let it
// reappear — the exact shape of the bug this ships alongside.
@MainActor
final class RideShareInServiceTests: XCTestCase {

    // MARK: - 1. In service ⇒ off and disabled, whatever is stored

    /// The core assertion, run across BOTH stored values: in service, the row is off
    /// and inert regardless of what the owner has stored. The `true` case is the one
    /// that matters — a car whose owner never paused it is the common case, and it
    /// is the one that used to render an ON switch on a car sitting in a workshop.
    func testInServiceRendersOffAndDisabledForEveryStoredValue() {
        for stored in [true, false] {
            let display = VehicleRideShare.display(storedEnabled: stored, isInService: true)
            XCTAssertFalse(display.isOn, "stored = \(stored): in service must render OFF")
            XCTAssertFalse(display.isInteractive, "stored = \(stored): in service must be inert")
            XCTAssertEqual(display.caption, VehicleRideShare.inServiceCaption)
        }
    }

    /// The caption must not reuse the owner's own "Paused" word. A car in a service
    /// bay was not withdrawn by anybody, and telling the owner it was "paused"
    /// invites them to go looking for the switch that did it.
    func testTheInServiceCaptionDoesNotClaimTheOwnerPausedTheCar() {
        XCTAssertFalse(
            VehicleRideShare.inServiceCaption.lowercased().contains("paused"),
            "in-service is not the owner's pause and must not borrow its word"
        )
        XCTAssertNotEqual(VehicleRideShare.inServiceCaption, VehicleRideShare.rowCaption(isEnabled: false))
    }

    // MARK: - 2. Leaving service restores the STORED value

    /// The property the whole derivation exists for. Nothing was written on the way
    /// in, so nothing has to be restored on the way out — the stored value simply
    /// renders again, in both directions.
    func testLeavingServiceRendersTheStoredValueAgain() {
        for stored in [true, false] {
            let inService = VehicleRideShare.display(storedEnabled: stored, isInService: true)
            XCTAssertFalse(inService.isOn)

            let after = VehicleRideShare.display(storedEnabled: stored, isInService: false)
            XCTAssertEqual(after.isOn, stored, "leaving service must reveal the STORED value, not the derived one")
            XCTAssertTrue(after.isInteractive)
            XCTAssertEqual(after.caption, VehicleRideShare.rowCaption(isEnabled: stored))
        }
    }

    /// An owner who PAUSED their car before it went in for service must still find
    /// it paused afterwards. Stated separately from the loop above because it is the
    /// case a "write false on entry, write true on exit" implementation gets
    /// silently wrong — and gets wrong in the direction that puts a car the owner
    /// withdrew back into ride-hailing.
    func testAPauseSurvivesAServiceVisit() {
        let stored = false
        _ = VehicleRideShare.display(storedEnabled: stored, isInService: true)
        let after = VehicleRideShare.display(storedEnabled: stored, isInService: false)
        XCTAssertFalse(after.isOn, "a service visit must never un-pause a car its owner paused")
    }

    // MARK: - 3. Tapping while disabled fires no write

    /// A disabled control that still commits is worse than an enabled one: nothing
    /// on screen predicts what it did. The row's binding refuses in addition to the
    /// switch being hit-test-disabled, so an accessibility action or any future
    /// programmatic path cannot reach §7.18 either.
    func testTappingWhileInServiceFiresNoWrite() {
        var writes: [Bool] = []
        let display = VehicleRideShare.display(storedEnabled: true, isInService: true)
        let model = RideShareRowModel(
            isEnabled: display.isOn,
            isInteractive: display.isInteractive,
            onToggle: { writes.append($0) },
            caption: display.caption
        )

        // Exactly what the row's `Binding` setter does.
        if model.isInteractive { model.onToggle(true) }

        XCTAssertTrue(writes.isEmpty, "an in-service row must not fire a §7.18 write")
    }

    /// The same row OUT of service is fully live — the guard must gate on the
    /// derivation, not on the toggle simply existing.
    func testTappingOutOfServiceStillWrites() {
        var writes: [Bool] = []
        let display = VehicleRideShare.display(storedEnabled: true, isInService: false)
        let model = RideShareRowModel(
            isEnabled: display.isOn,
            isInteractive: display.isInteractive,
            onToggle: { writes.append($0) },
            caption: display.caption
        )

        if model.isInteractive { model.onToggle(false) }

        XCTAssertEqual(writes, [false], "out of service the switch commits normally")
    }

    // MARK: - 4. The row model keeps the two facts apart

    /// "Off" and "not yours to move right now" are different facts, and a model that
    /// collapsed them could not render the state that proves it: a car its owner
    /// PAUSED, out of service, which is off AND editable.
    func testOffAndDisabledAreIndependent() {
        let pausedButEditable = VehicleRideShare.display(storedEnabled: false, isInService: false)
        XCTAssertFalse(pausedButEditable.isOn)
        XCTAssertTrue(pausedButEditable.isInteractive)
    }

    // MARK: - 5. Composition with MYR-351

    /// The ordering guard. The derivation sits ON TOP of
    /// `resolvedEnabled(committed:isCommitted:snapshot:)` and never replaces it, so
    /// the executor's committed value still outranks a stale snapshot underneath.
    ///
    /// Read the assertions as one sentence: the owner paused the car (committed
    /// `false`) while a stale snapshot still says `true`; MYR-351's resolver returns
    /// the committed `false`; and the moment the car leaves service that `false` —
    /// not the snapshot's `true` — is what the row shows.
    func testTheDerivationSitsOnTopOfTheCommittedResolutionNotInsteadOfIt() {
        let stored = VehicleRideShare.resolvedEnabled(
            committed: false,      // the owner just paused it
            isCommitted: true,
            snapshot: true         // a stale snapshot that predates the write
        )
        XCTAssertFalse(stored, "MYR-351: the committed value outranks a stale snapshot")

        // In service: derived off, and the stored value is carried through untouched.
        XCTAssertFalse(VehicleRideShare.display(storedEnabled: stored, isInService: true).isOn)

        // Out of service: the owner's own pause, not the snapshot's stale `true`.
        XCTAssertFalse(
            VehicleRideShare.display(storedEnabled: stored, isInService: false).isOn,
            "leaving service must reveal the COMMITTED value, never the stale snapshot"
        )
    }
}
