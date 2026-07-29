import SwiftUI
import XCTest
@testable import DesignSystem

final class PrimitiveTests: XCTestCase {
    // MARK: Battery

    /// jsx `batteryColor`: <20 low, <50 mid, else high; charging wins.
    func testBatteryColorThresholds() {
        XCTAssertEqual(Color.mrtBatteryColor(0), .mrtBatLow)
        XCTAssertEqual(Color.mrtBatteryColor(19.9), .mrtBatLow)
        XCTAssertEqual(Color.mrtBatteryColor(20), .mrtBatMid)
        XCTAssertEqual(Color.mrtBatteryColor(49.9), .mrtBatMid)
        XCTAssertEqual(Color.mrtBatteryColor(50), .mrtBatHigh)
        XCTAssertEqual(Color.mrtBatteryColor(100), .mrtBatHigh)
        XCTAssertEqual(Color.mrtBatteryColor(5, charging: true), .mrtCharging)
    }

    // MARK: Charge treatment (MYR-333)

    /// `MRTBatteryCharge.none` — every pre-MYR-333 call site — must resolve the
    /// EXACT colour the bar drew before, at every threshold. This is the
    /// pixel-identity guarantee the whole drift gate rests on.
    func testBatteryBarChargeNoneIsUnchanged() {
        for pct in [0.0, 12, 19.9, 20, 49.9, 50, 76, 100] {
            XCTAssertEqual(
                BatteryBar(pct: pct).fillColor, Color.mrtBatteryColor(pct),
                "charge: .none must be indistinguishable from the pre-MYR-333 bar at \(pct)%")
        }
        XCTAssertFalse(BatteryBar(pct: 76).isPulsing, "no session → no motion")
    }

    /// A live session commits to GREEN at EVERY state of charge — the client
    /// asked for "a clean pulsing green animation", and a single colour keeps the
    /// meaning single: green means charging, at 12% exactly as at 76%.
    ///
    /// Note this deliberately differs from `mrtBatteryColor(_:charging:)`, which
    /// is the prototype's amber "charging always wins" rule and stays untouched
    /// for `MiniBattery` and the showcase.
    func testChargingBarIsGreenAtEveryStateOfCharge() {
        for pct in [0.0, 12, 45, 76, 100] {
            XCTAssertEqual(
                BatteryBar(pct: pct, charge: .charging).fillColor, .mrtBatHigh,
                "a live session is green at \(pct)%, not the threshold colour")
        }
        XCTAssertNotEqual(
            BatteryBar(pct: 76, charge: .charging).fillColor, .mrtCharging,
            "the hero treatment is green, not the prototype's amber charging token")
    }

    /// `complete` keeps the green and DROPS the motion. The session is over, so a
    /// pulse would be a lie — the colour still says it ended well.
    func testCompleteIsGreenButStatic() {
        XCTAssertEqual(BatteryBar(pct: 100, charge: .complete).fillColor, .mrtBatHigh)
        XCTAssertFalse(
            BatteryBar(pct: 100, charge: .complete).isPulsing,
            "a finished session must not keep breathing")
    }

    // MARK: The travelling sweep (MYR-337)

    /// The client on the MYR-333 breath: "Charging pulse is really faint. It
    /// should pulse across smoothly." A whole-bar opacity fade has no direction;
    /// the highlight must actually TRAVEL. Its position is a strictly increasing
    /// function of the phase — the frame-diff evidence in the PR is the same
    /// claim measured on real pixels, this is it measured on the math.
    func testTheHighlightTravelsLeftToRightAcrossTheWholeCycle() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.05)
            .map { BatteryBar.sweepLocation(phase: $0) }
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThan(earlier, later, "the highlight must only ever move forward")
        }
    }

    /// It enters from OFF the left edge and leaves OFF the right, so the loop
    /// point carries no visible jump — the difference between "a highlight
    /// sweeping across" and "a highlight blinking on at the left".
    func testTheSweepStartsAndEndsClearOfTheBar() {
        XCTAssertLessThanOrEqual(
            BatteryBar.sweepLocation(phase: 0) + BatteryBar.sweepHalfBand, 0,
            "at the top of the cycle the band is entirely off the left edge")
        XCTAssertGreaterThanOrEqual(
            BatteryBar.sweepLocation(phase: 1) - BatteryBar.sweepHalfBand, 1,
            "at the bottom of the cycle the band is entirely off the right edge")
        // …and it does cross the middle on the way.
        XCTAssertEqual(BatteryBar.sweepLocation(phase: 0.5), 0.5, accuracy: 0.0001)
    }

    /// One traversal every 2.6s — the period the design's travelling-highlight
    /// grammar already runs at (`mrt-text-shimmer`, the CTA border trace).
    func testTheSweepSharesTheDesignsTravellingHighlightPeriod() {
        XCTAssertEqual(BatteryBar.sweepPeriod, 2.6)
        XCTAssertEqual(BatteryBar.sweepPeriod, MRTTextShimmer().duration)
    }

    /// Only an ACTIVE session pulses. (The Reduce Motion half of this rule is
    /// environment-driven — `isPulsing` reads `\.accessibilityReduceMotion` — so
    /// it is proven in the simulator captures, per CLAUDE.md's Reduce Motion
    /// drift-gate step, rather than asserted here.)
    func testOnlyAnActiveSessionPulses() {
        XCTAssertTrue(BatteryBar(pct: 76, charge: .charging).isPulsing)
        XCTAssertFalse(BatteryBar(pct: 76, charge: .none).isPulsing)
        XCTAssertFalse(BatteryBar(pct: 76, charge: .complete).isPulsing)
    }

    /// MiniBattery keeps its own jsx thresholds: ≤10 low, ≤20 mid.
    func testMiniBatteryThresholds() {
        XCTAssertEqual(MiniBattery(pct: 10).fillColor, .mrtBatLow)
        XCTAssertEqual(MiniBattery(pct: 20).fillColor, .mrtBatMid)
        XCTAssertEqual(MiniBattery(pct: 21).fillColor, .mrtBatHigh)
        XCTAssertEqual(MiniBattery(pct: 5, charging: true).fillColor, .mrtCharging)
    }

    // MARK: Honest-unknown captions (MYR-255 / MYR-279)

    func testValueAbsenceCaptions() {
        XCTAssertEqual(MRTValueAbsence.syncing.caption, "Syncing")
        XCTAssertEqual(MRTValueAbsence.unavailable.caption, "Unavailable")
        // MYR-279 — TPMS guides the owner rather than a bare "Unavailable".
        XCTAssertEqual(MRTValueAbsence.afterDrive.caption, "Available after your next drive")
    }

    // MARK: Trip progress

    func testTripProgressClamp() {
        XCTAssertEqual(TripProgressBar.clamped(0), 0.05)
        XCTAssertEqual(TripProgressBar.clamped(-1), 0.05)
        XCTAssertEqual(TripProgressBar.clamped(1), 0.95)
        XCTAssertEqual(TripProgressBar.clamped(2), 0.95)
        XCTAssertEqual(TripProgressBar.clamped(0.42), 0.42)
    }

    // MARK: Status map

    func testStatusMap() {
        XCTAssertEqual(MRTVehicleStatus.driving.label, "Driving")
        XCTAssertEqual(MRTVehicleStatus.parked.label, "Parked")
        XCTAssertEqual(MRTVehicleStatus.charging.label, "Charging")
        XCTAssertEqual(MRTVehicleStatus.offline.label, "Offline")
        XCTAssertEqual(MRTVehicleStatus.inService.label, "In Service")
        XCTAssertEqual(MRTVehicleStatus.driving.color, .mrtDriving)
        XCTAssertEqual(MRTVehicleStatus.parked.color, .mrtParked)
        XCTAssertEqual(MRTVehicleStatus.charging.color, .mrtCharging)
        XCTAssertEqual(MRTVehicleStatus.offline.color, .mrtOffline)
        XCTAssertEqual(MRTVehicleStatus.inService.color, .mrtInService)
    }

    // MARK: Avatar

    /// The JS hash sums UTF-16 char codes then mods by 360 —
    /// "Alex Chen" → 808 → 88.
    func testAvatarHueMatchesPrototypeHash() {
        XCTAssertEqual(Avatar.hue(for: "Alex Chen"), 88)
        XCTAssertEqual(Avatar.hue(for: "?"), 63)
        XCTAssertEqual(Avatar.hue(for: ""), 0)
    }

    func testAvatarInitials() {
        XCTAssertEqual(Avatar.initials(for: "Alex Chen"), "AC")
        XCTAssertEqual(Avatar.initials(for: "Jordan Lee Smith"), "JL")
        XCTAssertEqual(Avatar.initials(for: "?"), "?")
        XCTAssertEqual(Avatar.initials(for: "sam"), "S")
    }

    /// oklch(0.4 0.08 88) → sRGB(0.351369, 0.268444, 0.012671) per the
    /// CSS Color 4 reference math.
    func testOKLCHKnownValue() {
        let color = Avatar.oklch(l: 0.4, c: 0.08, hueDegrees: 88)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(Double(r), 0.351369, accuracy: 0.002)
        XCTAssertEqual(Double(g), 0.268444, accuracy: 0.002)
        XCTAssertEqual(Double(b), 0.012671, accuracy: 0.002)
        XCTAssertEqual(a, 1)
    }

    /// Every hue at L 0.4 / C 0.08 must resolve to a displayable color.
    func testOKLCHInGamutForAllHues() {
        for hue in stride(from: 0.0, through: 350.0, by: 10.0) {
            let color = Avatar.oklch(l: 0.4, c: 0.08, hueDegrees: hue)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a),
                "hue \(hue): not convertible"
            )
            for v in [r, g, b] {
                XCTAssertGreaterThanOrEqual(v, 0, "hue \(hue)")
                XCTAssertLessThanOrEqual(v, 1, "hue \(hue)")
            }
        }
    }

    // MARK: Tab models

    func testOwnerTabs() {
        XCTAssertEqual(MRTTab.ownerTabs.map(\.key), ["home", "drives", "invites", "settings"])
        XCTAssertEqual(MRTTab.ownerTabs.map(\.label), ["Vehicle", "Drives", "Share", "Settings"])
        XCTAssertEqual(MRTTab.ownerTabs.map(\.icon), ["car", "clock", "person.2", "gearshape"])
        XCTAssertEqual(
            MRTTab.ownerTabs.map(\.activeIcon),
            ["car.fill", "clock.fill", "person.2.fill", "gearshape.fill"]
        )
    }

    func testSharedTabs() {
        XCTAssertEqual(MRTTab.sharedTabs.map(\.key), ["shared", "rideHistory", "sharedSettings"])
        XCTAssertEqual(MRTTab.sharedTabs.map(\.label), ["Live Map", "Ride History", "Settings"])
        XCTAssertEqual(MRTTab.sharedTabs.map(\.icon), ["map", "clock", "gearshape"])
        XCTAssertEqual(MRTTab.sharedTabs.map(\.activeIcon), ["map.fill", "clock.fill", "gearshape.fill"])
    }

    // MARK: MYR-235 — map pins

    /// The two Tesla-style pin kinds stay distinct and render without trapping.
    func testMapPinKindsAreDistinct() {
        XCTAssertNotEqual(MRTMapPin.Kind.pickup, MRTMapPin.Kind.destination)
        _ = MRTMapPin(kind: .pickup).body
        _ = MRTMapPin(kind: .destination).body
    }

    /// The teardrop silhouette builds a closed path with its tip at the bottom
    /// center (the ground-contact / coordinate point under `.bottom` anchoring).
    func testTeardropTipAtBottomCenter() {
        let rect = CGRect(x: 0, y: 0, width: 15, height: 22)
        let path = Teardrop().path(in: rect)
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.currentPoint?.x ?? -1, rect.midX, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.maxY, rect.maxY, accuracy: 0.5)
    }

    // MARK: Route polyline

    func testRoutePolylineShapeBuildsOpenPath() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let path = RoutePolylineShape(points: points).path(in: .zero)
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingRect, CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertTrue(RoutePolylineShape(points: []).path(in: .zero).isEmpty)
    }

    // MARK: MYR-166 — sample route slicing (tutorials.jsx VigLiveMap/VigTrack)

    /// `MRTSampleRoute.sliced(into:)` ports the jsx's
    /// `preserveAspectRatio="xMidYMid slice"` (cover + center-crop) transform.
    func testSampleRouteSliceCoversAndCenters() {
        XCTAssertEqual(MRTSampleRoute.points.count, 12)
        let target = CGSize(width: 252, height: 252)
        let sliced = MRTSampleRoute.sliced(into: target)
        XCTAssertEqual(sliced.count, MRTSampleRoute.points.count)

        // "Slice" (cover) picks the *larger* of the two axis scales.
        let expectedScale = max(
            target.width / MRTSampleRoute.sourceSize.width,
            target.height / MRTSampleRoute.sourceSize.height
        )
        XCTAssertEqual(expectedScale, target.width / MRTSampleRoute.sourceSize.width, accuracy: 0.0001)

        // Spot-check the first point against the manual scale + center-crop math.
        let scaledSize = CGSize(
            width: MRTSampleRoute.sourceSize.width * expectedScale,
            height: MRTSampleRoute.sourceSize.height * expectedScale
        )
        let dx = (target.width - scaledSize.width) / 2
        let dy = (target.height - scaledSize.height) / 2
        let first = MRTSampleRoute.points[0]
        XCTAssertEqual(sliced[0].x, first.x * expectedScale + dx, accuracy: 0.01)
        XCTAssertEqual(sliced[0].y, first.y * expectedScale + dy, accuracy: 0.01)
    }

    func testSampleRouteSliceIdentityAtSourceSize() {
        let sliced = MRTSampleRoute.sliced(into: MRTSampleRoute.sourceSize)
        for (a, b) in zip(sliced, MRTSampleRoute.points) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
        }
    }

    // MARK: MYR-166 — seeded map RNG (components.jsx `seedRand`)

    /// Same seed ⇒ identical deterministic sequence (so two `MapBackground`
    /// instances with the same seed render pixel-identical street jitter).
    func testSeededMapRandomIsDeterministic() {
        var a = SeededMapRandom(seed: 42)
        var b = SeededMapRandom(seed: 42)
        for _ in 0..<20 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    /// Every draw lands in [0, 1) — the jsx divides by 233280, its own modulus.
    func testSeededMapRandomInUnitRange() {
        var rng = SeededMapRandom(seed: 7)
        for _ in 0..<200 {
            let v = rng.next()
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }

    func testSeededMapRandomDiffersAcrossSeeds() {
        var a = SeededMapRandom(seed: 42)
        var b = SeededMapRandom(seed: 7)
        XCTAssertNotEqual(a.next(), b.next())
    }
}
