import DesignSystem
@testable import MyRoboTaxi
import SwiftUI
import XCTest

// MARK: - MYR-345 (client defect) — "weird gap between menu and synced just now"
//
// Jul 29 TestFlight: *"Weird gap between menu and synced just now… I just want a
// clean looking gap that's not large but also enough room."* His screenshot
// (AKXUQLSW…) is an IN-SERVICE car, so its peek hero carries BOTH live-only
// qualifier lines at once — the service-completion line under the In Service
// badge and "Synced just now" at the foot.
//
// MYR-315 reserved a FLAT `homePeekQualifierLineHeight` (24) per live-only line.
// That number is right for the stamp and wrong for the completion line, which
// costs only ~16pt (a 12pt muted line grouped at 2pt under the header, not a
// standalone row with a 10pt lead). Over-reserving by ~8pt does not push anything
// around — the hero is top-aligned — so the whole surplus lands in ONE place: the
// void between the last line of the hero and the floating nav. Measured on the
// simulator before the fix: 43.0pt of clearance with no qualifier line (the
// prototype's own number for this hero), 42.0pt with the stamp, and 50.7pt with
// the completion line — the hole the client photographed.
//
// THE RULE THIS PINS: a live-only line must bring exactly its own room. Adding
// one may not change the distance between the hero's last ink and the floating
// nav, in ANY hero variant — so the peek band's per-line reserve has to equal
// what the line actually measures. Zero lines is the simulated / drift-gate path
// and must still land on the prototype's 210/280 exactly.
//
// These tests measure the REAL views (`ParkedSummary` / `DrivingSummary` through
// a `UIHostingController`, at the sheet's own content width) rather than
// re-deriving heights on paper, which is what let the 24 stand unchallenged.
@MainActor
final class OwnerPeekBandTests: XCTestCase {

    /// The sheet's peek layer: the base's stationary grab handle, then the
    /// content's own 6pt top pad (`HomeScreen`'s peek builder, screens.jsx:542).
    private static let contentTop = MRTMetrics.sheetGrabHandleHeight + 6

    /// The narrowest supported device, so a caption that wraps on a small screen
    /// shows up here as a taller hero rather than in a client screenshot
    /// (the MYR-335 lesson).
    private static let deviceWidth: CGFloat = 375

    private var contentWidth: CGFloat { Self.deviceWidth - 2 * MRTMetrics.pageGutter }

    /// The measured height of a hero as the peek layer lays it out.
    private func heroHeight<V: View>(_ view: V) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: contentWidth))
        host.view.backgroundColor = .clear
        let size = host.sizeThatFits(in: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        return size.height
    }

    /// Distance from the hero's LAST ink to the floating nav's top edge, which is
    /// the gap the client is looking at.
    private func clearance(peek: CGFloat, hero: CGFloat) -> CGFloat {
        peek - Self.contentTop - hero - MRTMetrics.bottomNavTopEdge
    }

    // MARK: Hero builders

    private func snapshot(
        driving: Bool,
        charging: VehicleChargingState = .idle,
        live: Bool = false
    ) -> VehicleTelemetrySnapshot {
        VehicleTelemetrySnapshot(
            status: driving ? .driving : .parked,
            progress: driving ? 0.42 : 0,
            speedMPH: driving ? 38 : 0,
            batteryPercent: 80,
            etaMinutes: driving ? 12 : 0,
            lastUpdated: live ? Date() : nil,
            isStreaming: live ? false : nil,
            chargingState: charging
        )
    }

    private var stamp: VehicleFreshnessStampModel {
        VehicleFreshnessStampModel(recency: .synced("just now"), phase: .idle, action: {})
    }

    private func parkedHero(
        stamp freshness: VehicleFreshnessStampModel?,
        serviceCompletion: String?,
        charging: VehicleChargingState = .idle
    ) -> some View {
        let vehicle = VehicleFixtures.vehicles.first { !$0.activity.isDriving }!
        return ParkedSummary(
            vehicle: vehicle,
            location: vehicle.activity.parkedLocation!,
            snapshot: snapshot(driving: false, charging: charging, live: freshness != nil),
            status: serviceCompletion == nil ? .parked : .inService,
            freshness: freshness,
            serviceCompletion: serviceCompletion
        )
    }

    private func drivingHero(
        stamp freshness: VehicleFreshnessStampModel?,
        // MYR-294 — the navigation state the hero is rendering. The default is
        // the fixture's own named destination, so every pre-existing assertion
        // below measures exactly the hero it always did.
        navigation: DrivingNavigation? = nil
    ) -> some View {
        let vehicle = VehicleFixtures.vehicles.first { $0.activity.isDriving }!
        guard case .driving(let fixtureTrip) = vehicle.activity else { preconditionFailure() }
        let trip = navigation.map {
            DrivingTrip(navigation: $0, originLabel: fixtureTrip.originLabel, originAddress: fixtureTrip.originAddress, route: fixtureTrip.route)
        } ?? fixtureTrip
        return DrivingSummary(
            vehicle: vehicle,
            trip: trip,
            snapshot: snapshot(driving: true, live: freshness != nil),
            freshness: freshness,
            currentLocation: trip.originLabel
        )
    }

    private func peek(driving: Bool, _ qualifiers: [MRTHomePeekQualifier]) -> CGFloat {
        MRTMetrics.homePeekHeight(
            base: driving ? MRTMetrics.homePeekHeightDriving : MRTMetrics.homePeekHeightParked,
            qualifiers: qualifiers
        )
    }

    /// The design's own clearance for a hero — what the PROTOTYPE's band leaves
    /// under it, with none of this port's live-only lines. It is not the same
    /// number for both heroes (210/280 are the prototype's numbers for two
    /// different blocks of content), and it is not ours to change: the simulated
    /// scenes render exactly this and the drift gate requires them byte-identical.
    private func baselineClearance(driving: Bool) -> CGFloat {
        clearance(
            peek: peek(driving: driving, []),
            hero: driving
                ? heroHeight(drivingHero(stamp: nil))
                : heroHeight(parkedHero(stamp: nil, serviceCompletion: nil))
        )
    }

    /// How far a qualifier line may move the clearance.
    ///
    /// This test measures LAYOUT boxes; the gap the owner actually sees is INK,
    /// and the two differ by however far a line's glyphs sit inside their own box
    /// — which is a property of the font at that size, not of the band. The
    /// reserves are tuned to ink parity off full-frame captures (see
    /// `MRTHomePeekQualifier.reservedHeight`, and the numbers in the PR), so the
    /// tolerance here is the ~2pt that difference is worth. It is still an order
    /// of magnitude under the 7.7pt hole this issue is about, which is the point:
    /// the rule under test is "a line may not quietly eat the band", not "these
    /// two constants are what they are".
    private static let tolerance: CGFloat = 2.0

    // MARK: THE DELIVERABLE

    /// THE CLIENT'S VARIANT — in service, read just now: both live-only lines at
    /// once. Before the fix this sat ~7.7pt below the prototype's own gap; his
    /// screenshot measures 49.7pt against the 43.0 the same hero shows with no
    /// qualifier line at all.
    func testClientsInServiceVariantKeepsThePrototypesGap() {
        let hero = heroHeight(parkedHero(stamp: stamp, serviceCompletion: "Service Estimated Completion \u{00B7} Sat, Aug 1 \u{00B7} 5:00 PM"))
        let measured = clearance(peek: peek(driving: false, [.serviceCompletion, .freshnessStamp]), hero: hero)
        XCTAssertEqual(measured, baselineClearance(driving: false), accuracy: Self.tolerance)
    }

    /// EVERY hero variant, one assertion each: parked/driving × stamp × service
    /// line × charging state. The gap under the hero must be the prototype's, in
    /// all of them.
    func testEveryHeroVariantKeepsItsPrototypeGap() {
        let line = "Service Estimated Completion \u{00B7} Sat, Aug 1 \u{00B7} 5:00 PM"
        let parkedBaseline = baselineClearance(driving: false)

        let parkedCases: [(String, [MRTHomePeekQualifier], CGFloat)] = [
            ("parked", [], heroHeight(parkedHero(stamp: nil, serviceCompletion: nil))),
            ("parked + stamp", [.freshnessStamp], heroHeight(parkedHero(stamp: stamp, serviceCompletion: nil))),
            ("parked + service", [.serviceCompletion], heroHeight(parkedHero(stamp: nil, serviceCompletion: line))),
            ("parked + service + stamp", [.serviceCompletion, .freshnessStamp],
             heroHeight(parkedHero(stamp: stamp, serviceCompletion: line))),
            ("parked + charging", [], heroHeight(parkedHero(stamp: nil, serviceCompletion: nil, charging: .charging))),
            ("parked + charge complete", [], heroHeight(parkedHero(stamp: nil, serviceCompletion: nil, charging: .complete))),
            ("parked + charging + service + stamp", [.serviceCompletion, .freshnessStamp],
             heroHeight(parkedHero(stamp: stamp, serviceCompletion: line, charging: .charging)))
        ]
        for (name, qualifiers, hero) in parkedCases {
            XCTAssertEqual(
                clearance(peek: peek(driving: false, qualifiers), hero: hero),
                parkedBaseline,
                accuracy: Self.tolerance,
                "\(name): the gap above the nav moved"
            )
        }

        let drivingBaseline = baselineClearance(driving: true)
        let drivingCases: [(String, [MRTHomePeekQualifier], CGFloat)] = [
            ("driving", [], heroHeight(drivingHero(stamp: nil))),
            ("driving + stamp", [.freshnessStamp], heroHeight(drivingHero(stamp: stamp)))
        ]
        for (name, qualifiers, hero) in drivingCases {
            XCTAssertEqual(
                clearance(peek: peek(driving: true, qualifiers), hero: hero),
                drivingBaseline,
                accuracy: Self.tolerance,
                "\(name): the gap above the nav moved"
            )
        }
    }

    /// The gap is a real one: "enough room", not flush. Both heroes clear the
    /// nav's top edge by a legible margin, and neither is so far off it that the
    /// hero looks detached from its own sheet (the client's "weird gap").
    func testTheGapIsSmallButRealInBothHeroes() {
        for driving in [false, true] {
            let gap = baselineClearance(driving: driving)
            XCTAssertGreaterThan(gap, 24, "driving=\(driving): the stamp would crowd the menu")
            XCTAssertLessThan(gap, 48, "driving=\(driving): that reads as a hole")
        }
    }

    // MARK: MYR-294 — the third hero

    /// How far the honest hero's LAYOUT clearance sits below the navigating
    /// hero's, at the ink-parity band — and why that is correct rather than a
    /// shortfall.
    ///
    /// MYR-345's rule is that the reserve is tuned against INK, because the gap
    /// the owner sees is measured from the last visible pixel. There the two
    /// differed by ~2pt. Here they differ by ~5, because the two heroes END ON
    /// DIFFERENT KINDS OF THING: the navigating hero's last element is
    /// `TripProgressBar`, whose 15pt orb (plus a 2pt ring) OVERFLOWS the bar's own
    /// 14pt frame, so its ink reaches ~2pt BELOW its layout box; the honest hero's
    /// is a 12pt location line, whose glyphs stop ~2pt ABOVE its own.
    ///
    /// Full-frame ink measurements on iPhone 17 Pro, which is what the band was
    /// actually tuned to: **42.7pt** of clearance for the navigating hero, 46.7pt
    /// at a layout-parity band of 238, and **42.7pt at 234**.
    ///
    /// It is carried EXPLICITLY, and bounded below, rather than absorbed by
    /// widening the tolerance — an offset a test states is one a reviewer can
    /// argue with, and the bound is what stops a real hole hiding behind it.
    private static let noNavigationInkOffset: CGFloat = 5

    /// The HONEST DRIVING HERO must leave the same gap above the nav that the two
    /// prototype heroes do.
    ///
    /// This is MYR-345's rule pointed the other way. That issue was about a
    /// live-only LINE being reserved MORE room than it measures, so the surplus
    /// landed in the one gap under a top-aligned hero. A car driving with no
    /// navigation renders a hero with three fewer elements — no destination
    /// headline, no "Arriving in N min · ETA h:mm" pair, no trip progress bar —
    /// and holding it at the prototype's 280 would put ~46 points into that same
    /// gap. A hero that gives lines back gives its room back.
    func testTheNoNavigationHeroKeepsTheDrivingGap() {
        let hero = heroHeight(drivingHero(stamp: nil, navigation: DrivingNavigation.none))
        let measured = clearance(peek: MRTMetrics.homePeekHeightDrivingNoNavigation, hero: hero)
        XCTAssertEqual(
            measured,
            baselineClearance(driving: true) - Self.noNavigationInkOffset,
            accuracy: Self.tolerance
        )
    }

    /// The same hero WITH the live-only freshness stamp — the realistic pairing,
    /// since this state is live-path-only and a live snapshot always carries a
    /// recency to be honest about.
    func testTheNoNavigationHeroKeepsItsGapWithTheStampToo() {
        let hero = heroHeight(drivingHero(stamp: stamp, navigation: DrivingNavigation.none))
        let peek = MRTMetrics.homePeekHeight(
            base: MRTMetrics.homePeekHeightDrivingNoNavigation,
            qualifiers: [.freshnessStamp]
        )
        XCTAssertEqual(
            clearance(peek: peek, hero: hero),
            baselineClearance(driving: true) - Self.noNavigationInkOffset,
            accuracy: Self.tolerance
        )
    }

    /// The offset is a FONT-METRICS correction, not a licence to under-reserve.
    /// The client's own complaint was worth ~7pt; anything approaching that is a
    /// hole, not a correction.
    func testTheInkOffsetStaysSmallEnoughToBeACorrection() {
        XCTAssertGreaterThan(Self.noNavigationInkOffset, 0)
        XCTAssertLessThan(
            Self.noNavigationInkOffset, 8,
            "an offset this large is a gap being explained away rather than a font-metrics difference"
        )
    }

    /// A destination whose NAME is still coming keeps the FULL driving band,
    /// because the skeleton stands exactly where the name will. The two must
    /// measure the same or the sheet visibly jumps the moment Tesla sends it.
    func testTheResolvingHeroIsTheSameHeightAsTheNamedOne() {
        XCTAssertEqual(
            heroHeight(drivingHero(stamp: nil, navigation: .resolvingDestination)),
            heroHeight(drivingHero(stamp: nil)),
            accuracy: Self.tolerance,
            "the skeleton occupies the destination line, so the block does not resize when the name lands"
        )
    }

    // MARK: The drift gate

    /// No live-only line ⇒ the prototype's bands EXACTLY. Every simulated scene
    /// renders zero of them, which is what keeps the drift gate byte-identical.
    func testNoQualifierLinesLeavesThePrototypesBandsUntouched() {
        XCTAssertEqual(peek(driving: false, []), MRTMetrics.homePeekHeightParked)
        XCTAssertEqual(peek(driving: true, []), MRTMetrics.homePeekHeightDriving)
    }

    /// The reserve is PER LINE and each line brings its own — the completion line
    /// is a grouped 12pt caption, the stamp a standalone row with a 10pt lead, and
    /// one number cannot be both.
    func testEachQualifierReservesItsOwnMeasuredHeight() {
        XCTAssertNotEqual(
            MRTHomePeekQualifier.serviceCompletion.reservedHeight,
            MRTHomePeekQualifier.freshnessStamp.reservedHeight
        )
        XCTAssertEqual(
            peek(driving: false, [.serviceCompletion, .freshnessStamp]),
            MRTMetrics.homePeekHeightParked
                + MRTHomePeekQualifier.serviceCompletion.reservedHeight
                + MRTHomePeekQualifier.freshnessStamp.reservedHeight
        )
    }
}
