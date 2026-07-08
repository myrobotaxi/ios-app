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

    /// MiniBattery keeps its own jsx thresholds: ≤10 low, ≤20 mid.
    func testMiniBatteryThresholds() {
        XCTAssertEqual(MiniBattery(pct: 10).fillColor, .mrtBatLow)
        XCTAssertEqual(MiniBattery(pct: 20).fillColor, .mrtBatMid)
        XCTAssertEqual(MiniBattery(pct: 21).fillColor, .mrtBatHigh)
        XCTAssertEqual(MiniBattery(pct: 5, charging: true).fillColor, .mrtCharging)
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
        XCTAssertEqual(MRTVehicleStatus.driving.color, .mrtDriving)
        XCTAssertEqual(MRTVehicleStatus.parked.color, .mrtParked)
        XCTAssertEqual(MRTVehicleStatus.charging.color, .mrtCharging)
        XCTAssertEqual(MRTVehicleStatus.offline.color, .mrtOffline)
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

    // MARK: MYR-169 — MRTSparkline geometry (screens.jsx `DSSparkline`, 1168-1183)

    /// `norm(v) = height - ((v - min) / (max - min || 1)) * (height - 14) - 8`
    /// — the min value should land near the bottom (height - 8) and the max
    /// value near the top (14 - 8 = 6), matching the jsx's 8pt/14pt insets.
    func testSparklineNormalizationBounds() {
        let values = [10.0, 20.0, 30.0, 40.0, 50.0]
        let points = MRTSparkline.normalizedPoints(values: values, width: 100, height: 60)
        XCTAssertEqual(points.count, values.count)
        guard let first = points.first, let last = points.last else {
            return XCTFail("expected normalized points")
        }
        XCTAssertEqual(Double(first.x), 0, accuracy: 0.001)
        XCTAssertEqual(Double(last.x), 100, accuracy: 0.001)
        // min value (10) → y = 60 - 0*(46) - 8 = 52
        XCTAssertEqual(Double(first.y), 52, accuracy: 0.001)
        // max value (50) → y = 60 - 1*(46) - 8 = 6
        XCTAssertEqual(Double(last.y), 6, accuracy: 0.001)
    }

    /// A flat series (`max - min == 0`) must not divide by zero — the jsx
    /// guards with `|| 1`.
    func testSparklineNormalizationFlatSeries() {
        let points = MRTSparkline.normalizedPoints(values: [5, 5, 5], width: 90, height: 40)
        for point in points {
            XCTAssertEqual(point.y, 40 - 8, accuracy: 0.001)
        }
    }

    func testSparklinePeakIndex() {
        XCTAssertEqual(MRTSparkline.peakIndex(values: [1, 5, 3, 9, 2]), 3)
        XCTAssertEqual(MRTSparkline.peakIndex(values: [4, 4, 4]), 0) // first-wins tie, matches jsx `v > values[peakI]`
    }

    func testSparklineFillPathClosesToBaseline() {
        let points = [CGPoint(x: 0, y: 10), CGPoint(x: 50, y: 5), CGPoint(x: 100, y: 20)]
        guard let path = MRTSparkline.fillPath(points: points, width: 100, height: 30) else {
            return XCTFail("expected a fill path")
        }
        // Closed fill area spans the full width/height (line points + the two
        // baseline-closing corners at (100,30) and (0,30)).
        let rect = path.boundingRect
        XCTAssertEqual(Double(rect.maxX), 100, accuracy: 0.001)
        XCTAssertEqual(Double(rect.maxY), 30, accuracy: 0.001)
    }
}
