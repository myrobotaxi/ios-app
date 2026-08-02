import CoreLocation
import DesignSystem
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - What the redesigned Live Activity renders (MYR-398, r16 redesign v3)
//
// The four surfaces cannot be tested. `ActivityViewContext` needs a real Activity
// in a real host process with a real installed widget extension, so a SwiftUI
// assertion about the lock screen is not available at any price — which is exactly
// why `RideActivityCard.resolve` exists as a pure function and why every view takes
// its output rather than a content state. Everything below drives that function.
//
// ─────────────────────────────────────────────────────────────────────────────
// SECTION 1 IS `design/la/la-data.jsx` (v3), ROW FOR ROW — ALL FOURTEEN.
//
// That file is the ANSWER KEY rather than an illustration, so the rows are written
// out with the design's own fixtures — `7SRJ294` / `Silver Model Y` /
// `Duarte's Tavern` — and each asserts EVERY decision the four surfaces read:
// headline, subline, rail fraction, rail variant, and the compact island.
//
// A row that renders differently from its entry in that table is a defect on THIS
// side. That is the whole point of writing them as literals: a helper that derived
// the expected value the same way the code does would agree with a wrong
// implementation.
//
// **FOURTEEN, NOT TWELVE.** v3 splits `Enroute · no ETA` from `Enroute · no
// telemetry` (the same headline over two different rails) and adds `Dispatch`,
// which is also the state the Activity now OPENS on for an instant ride.
// ─────────────────────────────────────────────────────────────────────────────
//
// Sections 2–8 are the rules the table cannot state as rows: the two headline
// FORMS, the retirement of "Arriving", the always-drawn rail, the vehicle
// descriptor's ladder, staleness, and the monotone hold.

final class RideActivityCardTests: XCTestCase {

    // The design's own fixtures, so the expected strings below can be read straight
    // off `la-data.jsx`.
    private static let plate = "7SRJ294"
    private static let color = "Silver"
    private static let model = "Model Y"
    private static let destination = "Duarte's Tavern"
    private static let vehicleNickname = "Cybercab"

    /// The board's own car, with NO year and NO trim — so the descriptor composes
    /// exactly `7SRJ294 · Silver Model Y`, which is the string every row asserts.
    /// The enrichment ladder gets its own section.
    private static let vehicle = RideActivityVehicle(
        plate: plate,
        color: color,
        model: model
    )

    private static let descriptor = "\(plate) · \(color) \(model)"

    /// A fixed instant, and a `now` a known distance before it.
    private let eta = Date(timeIntervalSince1970: 1_785_535_200)

    /// **A FIXED FORMATTER, SO `3:42 PM` CAN BE A LITERAL.**
    ///
    /// The clock string is the one thing on this surface that needs a LOCALE, which
    /// is why `resolve` takes the formatter rather than calling `.shortened`
    /// itself — the widget passes the system's answer and this passes a pinned one.
    /// Asserting on the system's would make the suite fail on a 24-hour device and
    /// say nothing about the card.
    private static let clock: (Date) -> String = { instant in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: instant)
    }

    /// What `Self.clock` renders the fixture ETA as, derived ONCE so the rows can
    /// name it and a timezone change cannot silently rewrite six assertions.
    private static let etaClock = clock(Date(timeIntervalSince1970: 1_785_535_200))

    private func state(
        _ status: LiveActivityRideStatus,
        eta etaSeconds: Int? = 1_785_535_200,
        vehicleName: String = vehicleNickname,
        destination: String = RideActivityCardTests.destination,
        progress: Double? = nil,
        asOf: Int? = nil
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: status,
            eta: etaSeconds,
            vehicleName: vehicleName,
            destination: destination,
            progress: progress,
            asOf: asOf
        )
    }

    /// Resolve a card at a FIXED moment.
    ///
    /// `now` defaults to 8.5 minutes before the fixture ETA, so a pickup-leg card
    /// renders the board's own "8 min" — through the truncation rule rather than by
    /// handing the formatter a whole number it cannot get wrong.
    ///
    /// Passing `now` at all is the point: since the client's 2026-07-31 ruling the
    /// figure is derived ONCE, here, from the frame's own moment, so the whole card
    /// is a deterministic function of its inputs.
    private func card(
        _ status: LiveActivityRideStatus,
        eta etaSeconds: Int? = 1_785_535_200,
        progress: Double? = nil,
        vehicle: RideActivityVehicle? = RideActivityCardTests.vehicle,
        destination: String = RideActivityCardTests.destination,
        vehicleName: String = vehicleNickname,
        isStale: Bool = false,
        asOf: Int? = nil,
        now: Date? = nil
    ) -> RideActivityCard {
        RideActivityCard.resolve(
            state: state(
                status,
                eta: etaSeconds,
                vehicleName: vehicleName,
                destination: destination,
                progress: progress,
                asOf: asOf
            ),
            vehicle: vehicle,
            isStale: isStale,
            now: now ?? eta.addingTimeInterval(-510),
            time: Self.clock
        )
    }

    private static let eightMinutes = RideActivityCountdown.Parts(value: "8", unit: "min")
    private static let oneMinute = RideActivityCountdown.Parts(value: "1", unit: "min")

    /// Everything the four surfaces read, as one value, so a row can be asserted in
    /// one statement and a missing assertion is visible as a missing field.
    private struct Rendered: Equatable, CustomStringConvertible {
        var headline: RideActivityHeadline
        var subline: String?
        var rail: RideActivityRailState
        var compact: RideActivityTrailingSlot
        /// MYR-398 §0 — the expanded island's `.trailing` slot, and the minimal
        /// island's whole content. It joins the row table rather than getting a
        /// table of its own, because it is the SAME ladder minus one rung and the
        /// pair is only readable side by side: every row where the two differ is a
        /// row where the compact island has a figure.
        var expandedTrailing: RideActivityTrailingSlot

        var description: String {
            "headline=\(headline) subline=\(String(describing: subline)) rail=\(rail)"
                + " compact=\(compact) expandedTrailing=\(expandedTrailing)"
        }
    }

    private func rendered(_ card: RideActivityCard) -> Rendered {
        Rendered(
            headline: card.headline,
            subline: card.subline,
            rail: card.rail,
            compact: card.compact,
            expandedTrailing: card.expandedTrailing
        )
    }

    // MARK: - 1. la-data.jsx (v3), row for row

    /// Row 1 · **Dispatch** — the state the Activity opens on, and the ONE row
    /// MYR-417 deliberately does not take from the board.
    ///
    /// la-data's own line is Uber's — `Finding your ride` / `Matching you with a
    /// ride`. There is no matching in this product: the rider asked ONE named car,
    /// and its plate, colour and model are known before the request is even sent.
    /// So the headline names the car and the subline is the SAME descriptor rows
    /// 2-6 carry. **The rail and both island slots are unchanged**, which is what
    /// keeps this a copy change: idle at zero, ring on both slots.
    func testRow01Dispatch() {
        XCTAssertEqual(
            rendered(card(.requested, eta: nil, progress: nil)),
            Rendered(
                headline: .sentence("Ride requested from Cybercab"),
                subline: Self.descriptor,
                rail: .idle,
                compact: .ringIndeterminate,
                expandedTrailing: .ringIndeterminate
            )
        )
    }

    /// **THE DISPATCH HEADLINE'S NAME LADDER — wire, then attribute, then generic.**
    ///
    /// Three sources of one string, and each arm exists because a different moment
    /// of a real ride reaches it. The WIRE's name is authoritative and wins whenever
    /// the server has sent one. The STATIC attribute is what the very first frame
    /// has — the Activity is requested before any push exists, which is the entire
    /// duration of the dispatch state on a healthy ride, so an implementation that
    /// read the wire alone would render "Your Tesla" for the one state this issue is
    /// about. And a car with no name anywhere is `Your Tesla`, the board's own
    /// nameless-vehicle rule rather than a second wording.
    func testTheDispatchHeadlineNamesTheCarTheRiderAsked() {
        let named = RideActivityVehicle(plate: "7SRJ294", color: "Silver", model: "Model Y", name: "Lunar")

        // 1 · the wire wins outright.
        XCTAssertEqual(
            card(.requested, eta: nil, vehicle: named, vehicleName: "Blue Whale").headline,
            .sentence("Ride requested from Blue Whale")
        )
        // 2 · an empty wire name — every locally-composed frame, including the
        // Activity's first — falls to the static attribute.
        XCTAssertEqual(
            card(.requested, eta: nil, vehicle: named, vehicleName: "").headline,
            .sentence("Ride requested from Lunar")
        )
        // 3 · whitespace is not a name either.
        XCTAssertEqual(
            card(.requested, eta: nil, vehicle: named, vehicleName: "   ").headline,
            .sentence("Ride requested from Lunar")
        )
        // 4 · nothing anywhere.
        XCTAssertEqual(
            card(.requested, eta: nil, vehicle: Self.vehicle, vehicleName: "").headline,
            .sentence("Ride requested from Your Tesla")
        )
        XCTAssertEqual(
            card(.requested, eta: nil, vehicle: nil, vehicleName: "").headline,
            .sentence("Ride requested from Your Tesla")
        )
    }

    /// **THE NICKNAME NEVER REACHES THE SUBLINE**, which is the other half of the
    /// same rule and the one a tidy refactor would break: `RideActivityVehicle` now
    /// carries a `name`, and the descriptor must keep ignoring it. A nickname
    /// describes nothing a rider can match against a car at a kerb — that is v3's
    /// reasoning and MYR-417 does not touch it.
    func testTheNicknameNamesTheHeadlineAndNeverTheDescriptor() {
        let named = RideActivityVehicle(
            plate: "7SRJ294", color: "Silver", model: "Model Y", name: "Lunar"
        )
        XCTAssertEqual(RideActivityVehicleDescriptor.compose(named), Self.descriptor)
        XCTAssertEqual(card(.requested, eta: nil, vehicle: named).subline, Self.descriptor)
        XCTAssertEqual(card(.accepted, vehicle: named).subline, Self.descriptor)
    }

    /// **A DISPATCH CARD WITH NO VEHICLE AT ALL STILL COMPOSES.** The subline falls
    /// to the same `Your Tesla` the headline does — the row keeps its 17pt either
    /// way, and neither line is ever blank.
    func testDispatchWithNoVehicleFallsBackOnBothLines() {
        let card = card(.requested, eta: nil, vehicle: nil, vehicleName: "")
        XCTAssertEqual(card.headline, .sentence("Ride requested from Your Tesla"))
        XCTAssertEqual(card.subline, "Your Tesla")
    }

    /// **THE RETIRED BOARD COPY APPEARS NOWHERE**, on any surface, in any state —
    /// the same sweep shape as `testNoSurfaceSaysArriving`, and for the same reason:
    /// a deleted constant can be re-typed as a literal by the next hand.
    func testNoSurfaceSaysMatching() {
        for status in LiveActivityRideStatus.allCases {
            for card in [card(status, progress: 0.4), card(status, eta: nil, progress: nil)] {
                for text in [Self.text(of: card.headline) ?? "", card.subline ?? ""] {
                    XCTAssertFalse(
                        text.lowercased().contains("matching"),
                        "\(status) says \"\(text)\""
                    )
                    XCTAssertFalse(
                        text.lowercased().contains("finding your ride"),
                        "\(status) says \"\(text)\""
                    )
                }
            }
        }
    }

    /// Row 2 · **Enroute** — the hero state, and the pickup leg's countdown FORM.
    func testRow02Enroute() {
        XCTAssertEqual(
            rendered(card(.accepted, progress: 0.38)),
            Rendered(
                headline: .pickupCountdown(Self.eightMinutes),
                subline: Self.descriptor,
                rail: .live(0.38),
                compact: .figure("8 min"),
                expandedTrailing: .ringDeterminate(0.38)
            )
        )
    }

    /// Row 3 · **Arriving** — its own PHASE, and deliberately not its own rendering.
    ///
    /// The card is byte-identical to row 2 apart from the figure and the fraction,
    /// which is the board's point: "same layout, just a smaller number — the rail
    /// being nearly full is what signals imminence".
    func testRow03Arriving() {
        let card = card(.accepted, progress: 0.88, now: eta.addingTimeInterval(-90))
        XCTAssertEqual(
            rendered(card),
            Rendered(
                headline: .pickupCountdown(Self.oneMinute),
                subline: Self.descriptor,
                rail: .live(0.88),
                compact: .figure("1 min"),
                expandedTrailing: .ringDeterminate(0.88)
            )
        )
    }

    /// Row 4 · **Enroute · no ETA** — one word swapped in the same slot, LIVE rail.
    func testRow04EnrouteWithNoETA() {
        XCTAssertEqual(
            rendered(card(.accepted, eta: nil, progress: 0.38)),
            Rendered(
                headline: .sentence("Pickup soon"),
                subline: Self.descriptor,
                rail: .live(0.38),
                compact: .ringDeterminate(0.38),
                expandedTrailing: .ringDeterminate(0.38)
            )
        )
    }

    /// Row 5 · **Enroute · no telemetry** — the SAME headline over the IDLE rail.
    ///
    /// The pair with row 4 is the whole reason v3 has fourteen rows rather than
    /// twelve: no ETA and no telemetry are two different states, and v2 rendered
    /// them identically (no rail at all in one, no rail at all in the other).
    func testRow05EnrouteWithNoTelemetry() {
        XCTAssertEqual(
            rendered(card(.accepted, eta: nil, progress: nil)),
            Rendered(
                headline: .sentence("Pickup soon"),
                subline: Self.descriptor,
                rail: .idle,
                compact: .ringIndeterminate,
                expandedTrailing: .ringIndeterminate
            )
        )
    }

    /// Row 6 · **Arrived** — full rail, the plate still in the subline, a WAVE.
    func testRow06Arrived() {
        XCTAssertEqual(
            rendered(card(.arrived, eta: nil, progress: 1)),
            Rendered(
                headline: .sentence("Your ride is here"),
                subline: Self.descriptor,
                rail: .live(1),
                compact: .glyph(.wave),
                expandedTrailing: .glyph(.wave)
            )
        )
    }

    /// Row 7 · **On trip** — the leg flip, and the CLOCK-TIME headline form.
    ///
    /// This is the state that used to read "Arriving in 17 min" — the line the field
    /// report was about.
    func testRow07OnTrip() {
        XCTAssertEqual(
            rendered(card(.enroute, progress: 0.52)),
            Rendered(
                headline: .dropoffClock(Self.etaClock),
                subline: "Heading to Duarte's Tavern",
                rail: .live(0.52),
                compact: .figure(Self.etaClock),
                expandedTrailing: .ringDeterminate(0.52)
            )
        )
    }

    /// Row 8 · **On trip · no ETA** — mirrors row 4 exactly, one word different.
    func testRow08OnTripWithNoETA() {
        XCTAssertEqual(
            rendered(card(.enroute, eta: nil, progress: 0.52)),
            Rendered(
                headline: .sentence("Dropoff soon"),
                subline: "Heading to Duarte's Tavern",
                rail: .live(0.52),
                compact: .ringDeterminate(0.52),
                expandedTrailing: .ringDeterminate(0.52)
            )
        )
    }

    /// Row 9 · **Pushes stopped** — the subline carries the admission, and NOTHING
    /// else about the card changes.
    ///
    /// The rail holds its fraction and STAYS GOLD (v2 desaturated it), and the
    /// compact island KEEPS the figure at full strength (v2 dimmed it to 45%).
    func testRow09PushesStopped() {
        // The board's own row, with the server's `asOf` on the wire (contracts
        // 0.28.0). `1_785_534_660` is 9 minutes before the fixture ETA, so the
        // subline dates itself from an instant in the PAST — which is the whole
        // point of the field being separate from `eta`.
        XCTAssertEqual(
            rendered(card(.enroute, progress: 0.52, isStale: true, asOf: 1_785_534_660)),
            Rendered(
                headline: .sentence("Dropoff soon"),
                subline: "Last updated \(Self.clock(Date(timeIntervalSince1970: 1_785_534_660)))",
                rail: .live(0.52),
                compact: .figure(Self.etaClock),
                expandedTrailing: .ringDeterminate(0.52)
            )
        )
    }

    /// Row 10 · **Completed** — the only other state whose rail completes.
    func testRow10Completed() {
        XCTAssertEqual(
            rendered(card(.completed, eta: nil, progress: 1)),
            Rendered(
                headline: .sentence("You've arrived"),
                subline: "Duarte's Tavern",
                rail: .live(1),
                compact: .glyph(.check),
                expandedTrailing: .glyph(.check)
            )
        )
    }

    /// Row 11 · **Declined** — "no blame on the owner", and no charge.
    func testRow11Declined() {
        XCTAssertEqual(
            rendered(card(.declined, eta: nil, progress: nil)),
            Rendered(
                headline: .sentence("No ride available"),
                subline: "Nothing was charged",
                rail: .idle,
                compact: .ringTrackOnly,
                expandedTrailing: .ringTrackOnly
            )
        )
    }

    /// Row 12 · **Cancelled** — subject-free: the rider may have cancelled it.
    func testRow12Cancelled() {
        XCTAssertEqual(
            rendered(card(.cancelled, eta: nil, progress: nil)),
            Rendered(
                headline: .sentence("Ride cancelled"),
                subline: "Nothing was charged",
                rail: .idle,
                compact: .ringTrackOnly,
                expandedTrailing: .ringTrackOnly
            )
        )
    }

    /// Row 13 · **Reservation expired** — headline is the outcome, subline the
    /// reason. Also the LONGEST headline in the set, which is what the fixed 24pt
    /// row and its one-line truncation are measured against.
    func testRow13ReservationExpired() {
        XCTAssertEqual(
            rendered(card(.reservationExpired, eta: nil, progress: nil)),
            Rendered(
                headline: .sentence("Reservation expired"),
                subline: "No car arrived in time",
                rail: .idle,
                compact: .ringTrackOnly,
                expandedTrailing: .ringTrackOnly
            )
        )
    }

    /// Row 14 · **Unknown status** — the arm the schema mandates tolerating.
    func testRow14UnknownStatus() {
        XCTAssertEqual(
            rendered(card(.unrecognized("boarding"), eta: nil, progress: nil)),
            Rendered(
                headline: .sentence("Ride in progress"),
                subline: "Tap to open MyRoboTaxi",
                rail: .idle,
                compact: .ringTrackOnly,
                expandedTrailing: .ringTrackOnly
            )
        )
    }

    // MARK: - 2. Two headline forms, one per leg

    /// **THE FIELD REPORT'S FIRST ITEM, AS AN ASSERTION.**
    ///
    /// *"It's saying arriving while on the way to the destination."* A duration and
    /// a time of day are now different SHAPES, so one can never be read as the
    /// other — and that is a property of the leg, not of the copy.
    func testThePickupLegCountsDownAndTheTripLegStatesAClockTime() {
        guard case .pickupCountdown = card(.accepted, progress: 0.38).headline else {
            return XCTFail("the pickup leg counts down")
        }
        guard case .dropoffClock = card(.enroute, progress: 0.52).headline else {
            return XCTFail("the trip leg states a clock time")
        }
    }

    /// The trip leg NEVER counts down — not at any remaining duration, and not on
    /// the frame where a minute-shaped figure would look perfectly plausible.
    func testTheTripLegNeverRendersACountdownHoweverCloseTheDropoffIs() {
        for secondsOut in [30, 90, 8 * 60, 45 * 60] {
            let card = card(
                .enroute,
                progress: 0.52,
                now: eta.addingTimeInterval(-Double(secondsOut))
            )
            guard case .dropoffClock = card.headline else {
                return XCTFail("\(secondsOut)s out still states a clock time")
            }
        }
    }

    /// The pickup leg NEVER states a clock time, for the mirror reason: a rider
    /// waiting at a kerb is asking "how long", not "at what time".
    func testThePickupLegNeverRendersAClockTime() {
        for secondsOut in [30, 90, 8 * 60, 45 * 60] {
            let card = card(
                .accepted,
                progress: 0.38,
                now: eta.addingTimeInterval(-Double(secondsOut))
            )
            guard case .pickupCountdown = card.headline else {
                return XCTFail("\(secondsOut)s out still counts down")
            }
        }
    }

    /// **"ARRIVING" IS BANNED FROM RIDER-FACING COPY.** It survives as a PHASE name
    /// for engineering and appears in no string on any surface.
    ///
    /// The sweep matters more than it looks: "Arriving" was v2's compact word for
    /// `enroute`, so this is the exact string the redesign had to remove and the
    /// exact place a careless revert would put it back.
    func testNoSurfaceSaysArriving() {
        for status in LiveActivityRideStatus.allCases {
            for stale in [false, true] {
                let card = card(status, progress: 0.5, isStale: stale)
                for text in [Self.text(of: card.headline), card.subline, Self.text(of: card.compact)] {
                    XCTAssertFalse(
                        (text ?? "").localizedCaseInsensitiveContains("arriving"),
                        "\(status) stale=\(stale) says 'Arriving'"
                    )
                }
            }
        }
    }

    /// **NEVER `mm:ss`.** `Text(timerInterval:)` renders exactly that and is
    /// therefore unusable; nothing this type emits may look like it either.
    func testTheCountdownIsNeverMMSS() {
        for secondsOut in [1, 30, 59, 61, 90, 250, 600, 3_600] {
            let parts = RideActivityCountdown.parts(
                until: eta,
                now: eta.addingTimeInterval(-Double(secondsOut))
            )
            XCTAssertFalse(parts.text.contains(":"), "\(secondsOut)s rendered \(parts.text)")
            XCTAssertTrue(["min", "s"].contains(parts.unit))
        }
    }

    /// `45 s` under a minute, `{n} min` at or above it — the board's own two units.
    func testAboveAMinuteItSaysMinutesAndBelowItSaysSeconds() {
        XCTAssertEqual(
            RideActivityCountdown.parts(until: eta, now: eta.addingTimeInterval(-45)),
            RideActivityCountdown.Parts(value: "45", unit: "s")
        )
        XCTAssertEqual(
            RideActivityCountdown.parts(until: eta, now: eta.addingTimeInterval(-60)),
            RideActivityCountdown.Parts(value: "1", unit: "min")
        )
    }

    /// TRUNCATED, never rounded up — "8 min" means "somewhere in the eighth minute".
    func testMinutesAreTruncatedAndNeverRoundedUp() {
        XCTAssertEqual(
            RideActivityCountdown.parts(until: eta, now: eta.addingTimeInterval(-(8 * 60 + 59))).value,
            "8"
        )
    }

    /// A LAPSED instant clamps to `0 s` rather than going negative or vanishing.
    func testALapsedInstantClampsToZeroSeconds() {
        XCTAssertEqual(
            RideActivityCountdown.parts(until: eta, now: eta.addingTimeInterval(90)),
            RideActivityCountdown.Parts(value: "0", unit: "s")
        )
    }

    /// **THE FIGURE IS HELD, AND NOTHING IN THE CARD CAN COUNT IT DOWN** — the
    /// client's 2026-07-31 ruling, as a structural property.
    ///
    /// Both surfaces are handed a composed STRING rather than an instant, so a view
    /// cannot re-derive one a second later even if it wanted to. The proof is that
    /// resolving the same content state at two different moments produces two
    /// different cards: the figure belongs to the FRAME, and only a new frame moves
    /// it.
    func testTheFigureIsHeldByTheFrameAndNotByAClock() {
        let early = card(.accepted, progress: 0.38, now: eta.addingTimeInterval(-510))
        let later = card(.accepted, progress: 0.38, now: eta.addingTimeInterval(-450))

        XCTAssertEqual(early.headline, .pickupCountdown(Self.eightMinutes))
        XCTAssertEqual(later.headline, .pickupCountdown(RideActivityCountdown.Parts(value: "7", unit: "min")))
        XCTAssertEqual(early.compact, .figure("8 min"))
        XCTAssertEqual(later.compact, .figure("7 min"))
    }

    /// The trip leg's clock does not move between frames at all, which is the whole
    /// reason the board chose it for the long leg: a time of day is true however
    /// late it is read.
    func testTheDropoffClockIsIdenticalAcrossFramesOfTheSameContentState() {
        XCTAssertEqual(
            card(.enroute, progress: 0.52, now: eta.addingTimeInterval(-900)).headline,
            card(.enroute, progress: 0.52, now: eta.addingTimeInterval(-120)).headline
        )
    }

    // MARK: - 3. The subline is a PLACE or an IDENTIFICATION, never a status

    /// The pickup leg names the CAR and the trip leg names the DESTINATION —
    /// swapping them is the v2 defect this row fixes ("Sansome & Clay" told a rider
    /// standing at Sansome & Clay where they were).
    func testThePickupLegNamesTheCarAndTheTripLegNamesThePlace() {
        XCTAssertEqual(card(.accepted, progress: 0.38).subline, Self.descriptor)
        XCTAssertEqual(card(.enroute, progress: 0.52).subline, "Heading to Duarte's Tavern")
    }

    /// The vehicle comes off the STATIC ATTRIBUTES, never off a push — so a frame
    /// carrying a different `vehicleName` cannot change the identification line.
    func testTheVehicleComesFromTheStaticAttributesAndNotFromThePush() {
        XCTAssertEqual(
            card(.accepted, progress: 0.38, vehicleName: "Blue Whale").subline,
            Self.descriptor
        )
    }

    /// **NO SUBLINE IS EVER A STATUS**, which is the rule the whole row exists for.
    /// Every string the fourteen rows can produce is a place, an identification, or
    /// a sentence about the ride's outcome — never a restatement of the headline.
    func testNoSublineRepeatsItsOwnHeadline() {
        for status in LiveActivityRideStatus.allCases {
            let card = card(status, progress: 0.5)
            guard let subline = card.subline, let headline = Self.text(of: card.headline) else { continue }
            XCTAssertNotEqual(subline, headline, "\(status)")
        }
    }

    /// An `enroute` frame whose destination is blank renders NO subline rather than
    /// "Heading to " — and the card's footprint does not move, because the row is a
    /// fixed height whatever is in it.
    func testABlankDestinationRendersNoSublineRatherThanADanglingPreposition() {
        XCTAssertNil(card(.enroute, progress: 0.52, destination: "   ").subline)
        XCTAssertNil(card(.completed, eta: nil, progress: 1, destination: "").subline)
    }

    // MARK: - 4. The vehicle descriptor's ladder

    /// The board's own grammar, exactly.
    func testTheDescriptorIsPlateThenColourThenModel() {
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(
                RideActivityVehicle(plate: "7SRJ294", color: "Silver", model: "Model Y")
            ),
            "7SRJ294 · Silver Model Y"
        )
    }

    /// **THE CLIENT'S ASK: YEAR AND TRIM, WHERE THEY FIT ONE LINE.**
    ///
    /// With a plate in front of it the full string is 41 characters and the ladder
    /// drops the TRIM — the least identifying fact at a kerb. Without a plate the
    /// same car keeps it, which is the ladder doing its job rather than a rule with
    /// two spellings.
    func testTheLadderDropsTheLeastIdentifyingPartFirst() {
        let enriched = RideActivityVehicle(
            plate: "7SRJ294", color: "Silver", model: "Model Y", year: 2026, trim: "Performance"
        )
        XCTAssertEqual(RideActivityVehicleDescriptor.compose(enriched), "7SRJ294 · Silver 2026 Model Y")

        var plateless = enriched
        plateless.plate = nil
        XCTAssertEqual(RideActivityVehicleDescriptor.compose(plateless), "Silver 2026 Model Y Performance")
    }

    /// Everything the ladder emits is inside the budget, at every rung — the
    /// property that makes "the line never chooses its own truncation" true rather
    /// than likely.
    func testEveryRungOfTheLadderIsInsideTheBudget() {
        let vehicles = [
            RideActivityVehicle(plate: "7SRJ294", color: "Silver", model: "Model Y", year: 2026, trim: "Performance"),
            RideActivityVehicle(plate: "7SRJ294", color: "Deep Blue Metallic", model: "Model S", year: 2026, trim: "Plaid"),
            RideActivityVehicle(plate: "8ABC123", color: "Quicksilver", model: "Model Y", year: 2025),
            RideActivityVehicle(color: "Pearl White Multi-Coat", model: "Model 3", year: 2026, trim: "Long Range"),
        ]
        for vehicle in vehicles {
            let composed = RideActivityVehicleDescriptor.compose(vehicle)
            XCTAssertLessThanOrEqual(
                composed.count,
                RideActivityVehicleDescriptor.maxCharacters,
                composed
            )
        }
    }

    /// A car whose every name is longer than the budget still renders the PLAINEST
    /// rung rather than an empty line — the ladder degrades, it does not give up.
    func testACarWhoseNamesExceedEveryRungStillRendersItsModel() {
        let absurd = RideActivityVehicle(
            plate: "PLATE1234567890",
            color: "An Extremely Long Marketing Paint Name",
            model: "Model Y Performance Long Range All Wheel Drive"
        )
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(absurd),
            "PLATE1234567890 · Model Y Performance Long Range All Wheel Drive"
        )
    }

    /// **A MISSING PLATE DROPS THE SEGMENT — NEVER A PLACEHOLDER.**
    ///
    /// This is the reason the Activity reads the RAW `VehicleSummary.licensePlate`
    /// rather than `VehicleContractMapping.plateDisplay`: that helper degrades to
    /// `VIN ····2046`, which is right for a labelled chip and wrong for a bare
    /// segment of a sentence.
    func testAMissingPlateDropsTheSegmentRatherThanDegradingToTheVIN() {
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(
                RideActivityVehicle(plate: nil, color: "Silver", model: "Model Y")
            ),
            "Silver Model Y"
        )
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(
                RideActivityVehicle(plate: "   ", color: "Silver", model: "Model Y")
            ),
            "Silver Model Y"
        )
    }

    /// A car with a plate and nothing else is still identified by it.
    func testAPlateWithNoCarWordsIsStillIdentification() {
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(RideActivityVehicle(plate: "7SRJ294")),
            "7SRJ294"
        )
    }

    /// **NAMELESS VEHICLE → "Your Tesla"**, the board's own fallback — and not the
    /// wire's `vehicleName`, which is the owner's nickname ("Lunar") and describes
    /// nothing a rider can see.
    func testANamelessVehicleReadsYourTesla() {
        XCTAssertEqual(RideActivityVehicleDescriptor.compose(nil), "Your Tesla")
        XCTAssertEqual(RideActivityVehicleDescriptor.compose(RideActivityVehicle()), "Your Tesla")
        XCTAssertEqual(
            card(.accepted, progress: 0.38, vehicle: nil, vehicleName: "Lunar").subline,
            "Your Tesla"
        )
    }

    /// A zero year is not a year. The wire's `VehicleSummary.year` is non-optional,
    /// so an unpopulated row arrives as `0` and would otherwise read
    /// "Silver 0 Model Y".
    func testAZeroYearIsDroppedRatherThanPrinted() {
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(
                RideActivityVehicle(color: "Silver", model: "Model Y", year: 0)
            ),
            "Silver Model Y"
        )
    }

    /// The five facts are read off the rider's OWN `GET /api/vehicles` row, and the
    /// TRIM is `nil` by construction because contracts 0.27.0's `VehicleSummary`
    /// carries none. Pinned, so the day the list row grows one this test is the
    /// thing that says so.
    func testTheSummaryReadTakesTheRawPlateAndNoTrim() {
        var summary = VehicleSummary(
            vehicleId: "v1",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Silver",
            vinLast4: "2046",
            status: .parked,
            chargeLevel: 68,
            estimatedRange: 240,
            lastUpdated: "2026-08-01T00:00:00Z",
            role: .owner
        )
        summary.licensePlate = "7SRJ294"

        let vehicle = RideActivityVehicle(summary: summary)
        XCTAssertEqual(vehicle.plate, "7SRJ294")
        XCTAssertEqual(vehicle.color, "Silver")
        XCTAssertEqual(vehicle.model, "Model Y")
        XCTAssertEqual(vehicle.year, 2026)
        XCTAssertNil(vehicle.trim, "contracts 0.27.0's VehicleSummary carries no trim at all")
        XCTAssertEqual(RideActivityVehicleDescriptor.compose(vehicle), "7SRJ294 · Silver 2026 Model Y")
    }

    /// **A CAR WITH NO OWNER-ENTERED PLATE MUST NOT BORROW THE VIN**, all the way
    /// through the shipping read rather than only in the composer.
    func testASummaryWithNoPlateComposesWithoutOne() {
        let summary = VehicleSummary(
            vehicleId: "v1",
            name: "Lunar",
            model: "Model 3",
            year: 2025,
            color: "Quicksilver",
            vinLast4: "2046",
            status: .parked,
            chargeLevel: 68,
            estimatedRange: 240,
            lastUpdated: "2026-08-01T00:00:00Z",
            role: .owner
        )
        XCTAssertEqual(
            RideActivityVehicleDescriptor.compose(RideActivityVehicle(summary: summary)),
            "Quicksilver 2025 Model 3"
        )
    }

    // MARK: - 5. The rail is ALWAYS drawn

    /// **NEVER ABSENT, NEVER DIMMED** — the field report's second and fourth items
    /// together, and the reason every state has the same footprint.
    func testEveryStateInTheMatrixDrawsARail() {
        for status in LiveActivityRideStatus.allCases {
            for progress in [nil, 0, 0.5, 1] as [Double?] {
                for stale in [false, true] {
                    let rail = card(status, progress: progress, isStale: stale).rail
                    XCTAssertTrue(
                        (0...1).contains(rail.progress),
                        "\(status) p=\(String(describing: progress)) stale=\(stale)"
                    )
                }
            }
        }
    }

    /// An absent fraction is the IDLE variant, not a live rail at zero — the
    /// §7.21.3 honesty rule, kept by drawing a different MARK rather than by drawing
    /// nothing.
    func testAnAbsentFractionIsTheIdleRailAndNotAGoldFillOfWidthZero() {
        XCTAssertEqual(card(.accepted, eta: nil, progress: nil).rail, .idle)
        XCTAssertTrue(card(.accepted, eta: nil, progress: nil).rail.isIdle)
    }

    /// A REPORTED zero is a live rail at zero, which is a different claim and must
    /// look different from the idle one.
    func testAReportedZeroIsALiveRailRatherThanTheIdleVariant() {
        let rail = card(.accepted, progress: 0).rail
        XCTAssertFalse(rail.isIdle)
        XCTAssertEqual(rail.progress, 0)
    }

    /// Every ENDING keeps an idle rail rather than collapsing, which is what makes
    /// a terminal card the same 128pt as a live one.
    func testEveryEndingKeepsTheIdleRailRatherThanCollapsing() {
        for status in [LiveActivityRideStatus.declined, .cancelled, .reservationExpired, .unrecognized("boarding")] {
            XCTAssertEqual(card(status, eta: nil, progress: 0.62).rail, .idle, "\(status)")
        }
    }

    /// **`arrived` AND `completed` ARE FULL ON THE STATUS'S AUTHORITY.** A frame
    /// that omitted the fraction still means the leg is over, so falling back to the
    /// idle rail there would draw an untravelled route under "Your ride is here".
    func testArrivedAndCompletedAreFullEvenWithNoFractionOnTheWire() {
        XCTAssertEqual(card(.arrived, eta: nil, progress: nil).rail, .live(1))
        XCTAssertEqual(card(.completed, eta: nil, progress: nil).rail, .live(1))
    }

    /// The ends are NOT clamped away the way `TripProgressBar` clamps them: that
    /// 0.05…0.95 floor is right for an illustrated bar and would quietly contradict
    /// a server that sends exactly `1`.
    func testTheEndsAreNotClampedAway() {
        XCTAssertEqual(card(.enroute, progress: 0).rail.progress, 0)
        XCTAssertEqual(card(.enroute, progress: 1).rail.progress, 1)
    }

    /// An out-of-range fraction is clamped INTO `0...1` rather than drawn off the
    /// rail.
    func testAnOutOfRangeFractionIsClamped() {
        XCTAssertEqual(card(.enroute, progress: 1.4).rail.progress, 1)
        XCTAssertEqual(card(.enroute, progress: -0.2).rail.progress, 0)
    }

    /// **STALENESS DOES NOTHING TO THE RAIL.** The last known position is still
    /// true; v2's desaturation is gone, and so is the token it used.
    func testStalenessHoldsTheRailAndLeavesItLive() {
        XCTAssertEqual(card(.enroute, progress: 0.52, isStale: true).rail, .live(0.52))
    }

    /// Every status resolves to the leg the contract says it is — the rail's reset
    /// key and both headline forms hang off this.
    func testEveryStatusResolvesToTheLegTheContractSaysItIs() {
        XCTAssertEqual(RideActivityLeg.of(.requested), .pickup)
        XCTAssertEqual(RideActivityLeg.of(.accepted), .pickup)
        XCTAssertEqual(RideActivityLeg.of(.arrived), .pickup)
        XCTAssertEqual(RideActivityLeg.of(.enroute), .dropoff)
        XCTAssertEqual(RideActivityLeg.of(.completed), .dropoff)
        for terminal in [LiveActivityRideStatus.declined, .cancelled, .reservationExpired, .unrecognized("x")] {
            XCTAssertNil(RideActivityLeg.of(terminal), "\(terminal)")
        }
    }

    // MARK: - 6. Staleness is one sentence, and nothing else

    /// The headline gives up its FIGURE — it does not freeze it. A frozen figure
    /// looks identical to a working one, which is the whole hazard.
    func testStalenessSwapsTheHeadlineRatherThanFreezingTheFigure() {
        XCTAssertEqual(card(.accepted, progress: 0.38, isStale: true).headline, .sentence("Pickup soon"))
        XCTAssertEqual(card(.enroute, progress: 0.52, isStale: true).headline, .sentence("Dropoff soon"))
    }

    /// The compact island KEEPS the last figure — the one place the island and the
    /// card disagree on purpose, and at FULL strength (v2 dimmed it to 45%).
    func testTheCompactIslandKeepsTheLastFigureWhileTheCardGivesUpItsHeadline() {
        XCTAssertEqual(card(.accepted, progress: 0.38, isStale: true).compact, .figure("8 min"))
        XCTAssertEqual(card(.enroute, progress: 0.52, isStale: true).compact, .figure(Self.etaClock))
    }

    /// **THE STALE SUBLINE DATES ITSELF FROM `asOf`** — contracts 0.28.0, the
    /// instant the SERVER last learned something, and deliberately NOT the `eta`.
    func testTheStaleSublineDatesItselfFromTheServersOwnInstant() {
        let asOf = 1_785_534_660
        let expected = "Last updated \(Self.clock(Date(timeIntervalSince1970: TimeInterval(asOf))))"
        for status in [LiveActivityRideStatus.requested, .accepted, .arrived, .enroute] {
            XCTAssertEqual(
                card(status, progress: 0.5, isStale: true, asOf: asOf).subline,
                expected,
                "\(status)"
            )
        }
    }

    /// **AND IT IS NEVER THE `eta`.** That one is a FUTURE instant chosen BEFORE the
    /// update that carried it, so a card dating its freshness notice from it would
    /// overstate freshness on the one card whose job is to admit it has none — v1
    /// shipped exactly that ("in 4 minutes ago"). The two instants are 9 minutes
    /// apart in these fixtures precisely so a regression to `eta` fails here.
    func testTheStaleSublineIsNeverDatedFromTheETA() {
        let subline = card(.enroute, progress: 0.52, isStale: true, asOf: 1_785_534_660).subline
        XCTAssertNotEqual(subline, "Last updated \(Self.etaClock)")
    }

    /// **AN OLDER SERVER OMITS THE KEY, AND THAT IS A LIVE ARM.** Absence means
    /// "this server does not say", never "just now", so the card falls back to the
    /// wordless sentence rather than inventing an instant.
    func testTheStaleSublineFallsBackWhenTheServerSendsNoInstant() {
        for status in [LiveActivityRideStatus.requested, .accepted, .arrived, .enroute] {
            XCTAssertEqual(
                card(status, progress: 0.5, isStale: true, asOf: nil).subline,
                "Waiting for an update",
                "\(status)"
            )
        }
    }

    /// A card whose `asOf` is RECENT reads normally — the field is only consulted
    /// against the horizon, never rendered on a fresh card.
    func testARecentAsOfLeavesTheCardFresh() {
        XCTAssertEqual(
            card(
                .accepted,
                progress: 0.38,
                asOf: Int(eta.addingTimeInterval(-540).timeIntervalSince1970),
                now: eta.addingTimeInterval(-510)
            ).subline,
            Self.descriptor
        )
    }

    // MARK: - 6b. The SECOND way a card goes stale (contracts 0.28.0)

    /// **THE CASE `asOf` WAS ADDED FOR, AND `context.isStale` CANNOT SEE.**
    ///
    /// The server's ETA ticker pushes unconditionally and every push re-arms
    /// `aps.stale-date`, so when the car goes quiet mid-leg ActivityKit never marks
    /// the Activity stale — the numbers keep arriving and the track just freezes,
    /// with nothing on the card explaining it. An `asOf` past the three-minute
    /// horizon is what says so.
    func testAFrozenAsOfMakesTheCardStaleEvenWhenActivityKitSaysItIsFresh() {
        let now = eta.addingTimeInterval(-510)
        let quiet = Int(now.addingTimeInterval(-600).timeIntervalSince1970)

        let card = card(.enroute, progress: 0.52, isStale: false, asOf: quiet, now: now)

        XCTAssertTrue(card.isStale, "ten minutes without the server learning anything")
        XCTAssertEqual(card.headline, .sentence("Dropoff soon"))
        XCTAssertEqual(
            card.subline,
            "Last updated \(Self.clock(Date(timeIntervalSince1970: TimeInterval(quiet))))"
        )
        XCTAssertEqual(card.rail, .live(0.52), "the rail HOLDS and stays gold")
    }

    /// The horizon is the contract's own three minutes, and it is the SAME constant
    /// the app arms a locally-composed frame's stale-date with.
    func testTheFreshnessHorizonIsThreeMinutesAndIsSharedWithTheAppsOwnWindow() {
        XCTAssertEqual(RideActivityFreshness.window, 3 * 60)
        XCTAssertEqual(RideActivityStaleness.window, RideActivityFreshness.window)

        let now = Date(timeIntervalSince1970: 1_785_535_200)
        XCTAssertFalse(
            RideActivityFreshness.hasGoneQuiet(asOf: now.addingTimeInterval(-179), now: now)
        )
        XCTAssertFalse(
            RideActivityFreshness.hasGoneQuiet(asOf: now.addingTimeInterval(-180), now: now),
            "exactly at the horizon is still fresh — the comparison is strict"
        )
        XCTAssertTrue(
            RideActivityFreshness.hasGoneQuiet(asOf: now.addingTimeInterval(-181), now: now)
        )
    }

    /// **AN ABSENT `asOf` IS NEVER STALE**, and this is the guard that keeps an
    /// un-upgraded server (and the app's own backstop frames, which never invent an
    /// instant) from rendering "Waiting for an update" on a perfectly live card.
    func testAnAbsentAsOfIsNeverTreatedAsQuiet() {
        let now = Date(timeIntervalSince1970: 1_785_535_200)
        XCTAssertFalse(RideActivityFreshness.hasGoneQuiet(asOf: nil, now: now))
        XCTAssertFalse(card(.accepted, progress: 0.38, asOf: nil).isStale)
    }

    /// Clock skew between a server and a phone is ordinary, so an `asOf` in the
    /// FUTURE reads as "just now" rather than as a negative age.
    func testAFutureAsOfIsNotStale() {
        let now = Date(timeIntervalSince1970: 1_785_535_200)
        XCTAssertFalse(
            RideActivityFreshness.hasGoneQuiet(asOf: now.addingTimeInterval(30), now: now)
        )
    }

    /// ActivityKit's verdict still stands on its own — the two are OR'd, so a card
    /// with no `asOf` at all still goes stale the way it always did.
    func testActivityKitsOwnVerdictStillMakesACardStaleWithNoAsOf() {
        XCTAssertTrue(card(.enroute, progress: 0.52, isStale: true, asOf: nil).isStale)
    }

    /// A TERMINAL card is not "waiting for an update": the outcome cannot change,
    /// and saying otherwise would suggest it might.
    func testATerminalCardKeepsItsOwnSublineWhenStale() {
        XCTAssertEqual(card(.cancelled, eta: nil, isStale: true).subline, "Nothing was charged")
        XCTAssertEqual(card(.completed, eta: nil, progress: 1, isStale: true).subline, "Duarte's Tavern")
    }

    /// The word *stale* never renders anywhere. It is ActivityKit's vocabulary, not
    /// a rider's — and v2's "Not updating" chip went with the chip.
    func testTheWordStaleNeverRendersAnywhere() {
        for status in LiveActivityRideStatus.allCases {
            for progress in [nil, 0.5, 1] as [Double?] {
                let card = card(status, progress: progress, isStale: true)
                for text in [Self.text(of: card.headline), card.subline, Self.text(of: card.compact)] {
                    XCTAssertFalse((text ?? "").localizedCaseInsensitiveContains("stale"), "\(status)")
                    XCTAssertFalse((text ?? "").localizedCaseInsensitiveContains("not updating"), "\(status)")
                }
            }
        }
    }

    // MARK: - 7. The compact island is a figure, a glyph, or the ring

    /// **NO STATUS WORD SURVIVES ANYWHERE IN THE MATRIX.** Every string v2 put in
    /// this slot is deleted, and with it the width ladder that table needed.
    func testTheCompactIslandNeverRendersAStatusWord() {
        let v2Words = [
            "Requested", "On the way", "Arrived", "Arriving", "Dropped off", "Ride ended", "Ride",
        ]
        for status in LiveActivityRideStatus.allCases {
            for stale in [false, true] {
                let compact = card(status, progress: 0.5, isStale: stale).compact
                guard case .figure(let figure) = compact else { continue }
                XCTAssertFalse(v2Words.contains(figure), "\(status) rendered the v2 word \(figure)")
            }
        }
    }

    /// A figure in that slot is ALWAYS one of the two shapes the board allows.
    func testEveryCompactFigureIsAnETAFigureOrAClockTime() {
        for status in LiveActivityRideStatus.allCases {
            guard case .figure(let figure) = card(status, progress: 0.5).compact else { continue }
            let isCountdown = figure.hasSuffix(" min") || figure.hasSuffix(" s")
            XCTAssertTrue(isCountdown || figure == Self.etaClock, "\(status) → \(figure)")
        }
    }

    /// The two glyph states, and only those two.
    func testTheGlyphsAreTheWaveAtTheKerbAndTheCheckAtTheEnd() {
        for status in LiveActivityRideStatus.allCases {
            let compact = card(status, progress: 0.5).compact
            switch status {
            case .arrived: XCTAssertEqual(compact, .glyph(.wave))
            case .completed: XCTAssertEqual(compact, .glyph(.check))
            default: XCTAssertNotEqual(compact, .glyph(.wave), "\(status)")
            }
        }
    }

    /// **A STATE WITH NO FIGURE SHOWS THE RING** (MYR-398 §0 B).
    ///
    /// This test is the clearest before/after in the suite: every one of these four
    /// rows resolved to `.markOnly` in v3 — an empty half-pill beside the mark, which
    /// is what the client photographed on a live ride with no telemetry and read as a
    /// dead app. Each now resolves to the ring MODE that says what is actually true
    /// of it, and the four are deliberately four different answers.
    func testAStateWithNoFigureShowsTheRing() {
        // Dispatch — a live ride with no car yet. The rotation IS the message.
        XCTAssertEqual(card(.requested, eta: nil).compact, .ringIndeterminate)
        // No ETA, but telemetry IS arriving: the arc is the rail's own fraction.
        XCTAssertEqual(card(.accepted, eta: nil, progress: 0.38).compact, .ringDeterminate(0.38))
        XCTAssertEqual(card(.enroute, eta: nil, progress: 0.52).compact, .ringDeterminate(0.52))
        // An ending is not waiting on anything and is not in progress.
        XCTAssertEqual(card(.declined, eta: nil).compact, .ringTrackOnly)
    }

    /// **DISPATCH NEVER COUNTS DOWN**, even if a stale `eta` is sitting in the
    /// content state: the owner has not accepted, so there is nothing for a countdown
    /// to be about — the car being KNOWN (MYR-417) does not make its arrival known.
    func testDispatchNeverCountsDownEvenWithAnETAOnTheWire() {
        let card = card(.requested, progress: nil)
        XCTAssertEqual(card.headline, .sentence("Ride requested from Cybercab"))
        XCTAssertEqual(card.compact, .ringIndeterminate)
    }

    /// A TERMINAL card never counts down either — the "never a confident stale ETA"
    /// rule applied to the state rather than to the clock.
    func testATerminalCardNeverRendersAFigureHoweverTheWireIsShaped() {
        for status in [LiveActivityRideStatus.completed, .declined, .cancelled, .reservationExpired, .unrecognized("x")] {
            let card = card(status, progress: 0.5)
            if case .figure = card.compact { XCTFail("\(status) rendered a figure") }
            if case .pickupCountdown = card.headline { XCTFail("\(status) counted down") }
            if case .dropoffClock = card.headline { XCTFail("\(status) stated a clock") }
        }
    }

    // MARK: - 7a. MYR-418 — the completion sequence the server now sends

    // ─────────────────────────────────────────────────────────────────────────
    // **THE SERVER SPLIT THE COMPLETION IN TWO, AND THE SECOND HALF IS THE INPUT
    // §0 C's ONCE-ONLY RULE WAS WRITTEN FOR.**
    //
    // Apple silently ignores `aps.alert` on an END event, so the single alerted end
    // never expanded the island — the client's missing check mark. MYR-418 sends the
    // completed content state TWICE: an alerted UPDATE, then the alert-free END
    // carrying the same state ~1s later.
    //
    // What this side has to be true of that sequence is three things, and all three
    // are properties of `resolve` rather than of a view — which is the whole reason
    // they can be asserted at all:
    //
    //   (a) the UPDATE-delivered completed state resolves to the check, on both
    //       island slots, with the rail full;
    //   (b) the END re-delivering the SAME state resolves to a card EQUAL to the
    //       first — which is the structural precondition for the beat not replaying,
    //       because every value it animates is a pure function of this resolution and
    //       `.animation(_:value:)` fires only on a CHANGE;
    //   (c) a COLD end-only delivery — the Activity started late and never saw the
    //       update — resolves to that same card, so it renders the settled check with
    //       nothing to animate from.
    // ─────────────────────────────────────────────────────────────────────────

    /// (a) The completed state as the UPDATE delivers it.
    func testTheCompletedUpdateResolvesToTheCheckOnBothIslandSlots() {
        let completed = card(.completed, eta: nil, progress: 1)
        XCTAssertEqual(completed.compact, .glyph(.check))
        XCTAssertEqual(completed.expandedTrailing, .glyph(.check))
        XCTAssertEqual(completed.rail, .live(1))
        XCTAssertEqual(completed.headline, .sentence("You've arrived"))
    }

    /// (b) **THE END RE-DELIVERS THE SAME STATE AND THE CARD DOES NOT MOVE.**
    ///
    /// The two frames are one second apart on the wire and identical in content, so
    /// the assertion is EQUALITY of the whole resolution — not of the glyph alone.
    /// The glyph alone would pass with a resolver that had started returning a
    /// different rail or a different headline on the second frame, and the beat is
    /// keyed on the SLOT, which is derived from all of it.
    ///
    /// It is asserted across a moving `now`, because the second delivery lands a real
    /// second later and a resolution that quietly depended on the clock would replay
    /// the beat once a ride in production.
    func testTheEndAfterTheUpdateResolvesToAnIdenticalCardAndCannotReplayTheBeat() {
        let state = state(.completed, eta: nil, progress: 1)
        let update = RideActivityCard.resolve(
            state: state, vehicle: Self.vehicle, isStale: false,
            now: eta, time: Self.clock
        )
        // The END, one second later, carrying the SAME content state verbatim.
        let end = RideActivityCard.resolve(
            state: state, vehicle: Self.vehicle, isStale: false,
            now: eta.addingTimeInterval(1), time: Self.clock
        )
        XCTAssertEqual(update, end, "the end frame must be indistinguishable from the update's")
        XCTAssertEqual(end.compact, .glyph(.check))
        XCTAssertEqual(end.expandedTrailing, .glyph(.check))
    }

    /// (c) **THE COLD END-ONLY DELIVERY RENDERS THE SETTLED CHECK.**
    ///
    /// An Activity that started late, or an app relaunched between the two
    /// deliveries, meets the completed state for the first time as the END. There is
    /// no transition to animate and there must be no attempt to invent one: the card
    /// it resolves to is byte-identical to the one the update produced, so the view
    /// draws the same settled frame with nothing changing under it.
    func testAColdEndOnlyDeliveryResolvesToTheSameSettledCheck() {
        let cold = card(.completed, eta: nil, progress: 1)
        let afterUpdate = card(.completed, eta: nil, progress: 1)
        XCTAssertEqual(cold, afterUpdate)
        XCTAssertEqual(cold.compact, .glyph(.check))

        // And a completed frame the server sent with NO fraction is still full: the
        // status is the authority, so an end that omitted `progress` cannot draw an
        // untravelled route under "You've arrived".
        XCTAssertEqual(card(.completed, eta: nil, progress: nil).rail, .live(1))
        XCTAssertEqual(card(.completed, eta: nil, progress: nil).compact, .glyph(.check))
    }

    // MARK: - 7b. §0 — the trailing-slot ladder, the ring, and the beat

    /// **THE LADDER RESOLVES STRICTLY, AND THE RING NEVER DISPLACES A NUMBER.**
    ///
    /// §0 D's whole risk is over-application: a ring is a nicer thing to look at than
    /// an empty pill, which makes it tempting in slots that already say something. So
    /// the assertion is stated as the negative — every state that had a figure before
    /// §0 still has exactly that figure, byte for byte.
    func testTheFigureOutranksTheRingOnEveryStateThatHasOne() {
        XCTAssertEqual(card(.accepted, progress: 0.38).compact, .figure("8 min"))
        XCTAssertEqual(
            card(.accepted, progress: 0.88, now: eta.addingTimeInterval(-90)).compact,
            .figure("1 min")
        )
        XCTAssertEqual(card(.enroute, progress: 0.52).compact, .figure(Self.etaClock))
        // Stale keeps the last figure too — §0 lists "Stale unchanged" by name.
        XCTAssertEqual(
            card(.enroute, progress: 0.52, isStale: true, asOf: 1_785_534_660).compact,
            .figure(Self.etaClock)
        )
    }

    /// The two rungs above the ring are DISJOINT, which is why the ladder's order can
    /// never actually be observed — and is worth pinning, because the day a terminal
    /// state is allowed a figure is the day the order starts to matter.
    func testNoStateCanEverSatisfyBothTheFigureRungAndTheGlyphRung() {
        for status in LiveActivityRideStatus.allCases where status == .arrived || status == .completed {
            XCTAssertFalse(
                RideActivityCopy.showsFigure(for: status),
                "\(status) would make the ladder's order load-bearing"
            )
        }
    }

    /// **THE RING'S THREE MODES, ONE ROW EACH.**
    func testTheRingSaysADifferentThingInEachOfItsThreeModes() {
        // 1 · telemetry flowing → the RAIL'S OWN fraction.
        XCTAssertEqual(card(.accepted, eta: nil, progress: 0.38).expandedTrailing, .ringDeterminate(0.38))
        // 2 · a LIVE ride whose car has reported nothing → the rotation.
        XCTAssertEqual(card(.accepted, eta: nil, progress: nil).expandedTrailing, .ringIndeterminate)
        XCTAssertEqual(card(.requested, eta: nil).expandedTrailing, .ringIndeterminate)
        // 3 · an ENDED ride → the track alone.
        for ending in [LiveActivityRideStatus.declined, .cancelled, .reservationExpired] {
            XCTAssertEqual(card(ending, eta: nil).expandedTrailing, .ringTrackOnly, "\(ending)")
        }
    }

    /// **THE ARC IS THE RAIL'S OWN NUMBER — ONE SOURCE, SO THE TWO SURFACES CANNOT
    /// DISAGREE.** Swept rather than sampled: a second reading of `progress` would
    /// pass a spot check and drift on the clamp, the floor or the leg rule.
    func testTheDeterminateArcIsTheSameFractionTheRailDraws() {
        for progress in [0.0, 0.02, 0.13, 0.38, 0.52, 0.88, 1.0] {
            for status in [LiveActivityRideStatus.accepted, .enroute] {
                let resolved = card(status, eta: nil, progress: progress)
                guard case .ringDeterminate(let arc) = resolved.expandedTrailing else {
                    return XCTFail("\(status) at \(progress) drew no arc")
                }
                XCTAssertEqual(
                    arc,
                    max(RideActivityMetrics.ringMinimumArc, resolved.rail.progress),
                    accuracy: 0.0001,
                    "\(status) at \(progress)"
                )
            }
        }
    }

    /// A round cap on a zero-length arc draws NOTHING, so a determinate ring at zero
    /// would render as the track-only state — a different claim entirely.
    func testTheArcIsFlooredSoItsCapIsAlwaysVisible() {
        XCTAssertEqual(card(.enroute, eta: nil, progress: 0).expandedTrailing, .ringDeterminate(0.02))
        XCTAssertEqual(
            card(.enroute, eta: nil, progress: 0.001).expandedTrailing,
            .ringDeterminate(0.02),
            "the floor is a floor, not a special case for exactly zero"
        )
    }

    /// **THE ENDED TEST IS THE LEG RULE, NOT A SECOND LIST OF STATUSES.**
    ///
    /// Swept over the whole enum so a status added later cannot get a spinner beside
    /// "Ride cancelled" by being left off a hand-written list.
    func testTheRingIsTrackOnlyForExactlyTheStatusesWithNoLeg() {
        for status in LiveActivityRideStatus.allCases {
            let slot = card(status, eta: nil, progress: nil).expandedTrailing
            XCTAssertEqual(
                slot == .ringTrackOnly,
                RideActivityLeg.of(status) == nil,
                "\(status): slot=\(slot), leg=\(String(describing: RideActivityLeg.of(status)))"
            )
        }
    }

    /// **THE EXPANDED SLOT IS GLYPH-OR-RING, NEVER EMPTY AND NEVER THE ETA** — swept
    /// over the whole matrix, because "never" is the kind of claim one state gets to
    /// break.
    func testTheExpandedTrailingSlotIsNeverAFigureAndNeverEmpty() {
        for status in LiveActivityRideStatus.allCases {
            for progress in [nil, 0.0, 0.5, 1.0] as [Double?] {
                for stale in [false, true] {
                    let slot = card(status, progress: progress, isStale: stale).expandedTrailing
                    if case .figure = slot {
                        XCTFail("\(status) put the ETA in the expanded slot")
                    }
                    XCTAssertTrue(slot.drawsRing, "\(status) left the expanded slot empty")
                }
            }
        }
    }

    /// **MYR-412 — THE ARRIVAL GLYPH STANDS ALONE ON BOTH BARE SURFACES.**
    ///
    /// The client's board has the wave and the check with nothing around them, and
    /// the ring only where there is neither a glyph nor a figure: *"why is there a
    /// circle around the hand thats not needed"*. `drawsBareRing` is the compact
    /// trailing slot's and the expanded `.trailing` region's question, and it is the
    /// exact complement of "this rung is a glyph or a figure" — swept, so a rung added
    /// later has to answer it rather than inheriting a `true`.
    func testTheArrivalGlyphNeverDrawsARingOnTheBareSurfaces() {
        for status in LiveActivityRideStatus.allCases {
            for progress in [nil, 0.0, 0.38, 1.0] as [Double?] {
                for stale in [false, true] {
                    let resolved = card(status, progress: progress, isStale: stale)
                    for (name, slot) in [
                        ("compact", resolved.compact),
                        ("expanded", resolved.expandedTrailing),
                    ] {
                        if let glyph = slot.bareGlyph {
                            XCTAssertFalse(
                                slot.drawsBareRing,
                                "\(status) · \(name): a \(glyph) glyph inside a ring is the reported defect"
                            )
                        } else if case .figure = slot {
                            XCTAssertFalse(slot.drawsBareRing, "\(status) · \(name): a ring behind a number")
                        } else {
                            XCTAssertTrue(
                                slot.drawsBareRing,
                                "\(status) · \(name): neither a glyph, nor a figure, nor a ring — an empty slot"
                            )
                        }
                    }
                }
            }
        }
    }

    /// **THE MINIMAL ISLAND IS THE EXCEPTION, AND IT IS ONE ON PURPOSE.**
    ///
    /// `drawsRing` is what that surface asks and it still answers `true` for a glyph:
    /// minimal is the lone 37pt circle another app's Activity leaves us, and the mark
    /// inside the ring is the only thing on it that says whose ride this is. The two
    /// accessors disagreeing about exactly `.glyph` — and about nothing else — IS the
    /// rule, so it is asserted rather than left to two call sites.
    func testTheTwoRingQuestionsDifferOnExactlyTheGlyphRung() {
        for status in LiveActivityRideStatus.allCases {
            for progress in [nil, 0.38, 1.0] as [Double?] {
                let slot = card(status, progress: progress).expandedTrailing
                XCTAssertEqual(
                    slot.drawsRing != slot.drawsBareRing,
                    slot.bareGlyph != nil,
                    "\(status): drawsRing=\(slot.drawsRing) drawsBareRing=\(slot.drawsBareRing) slot=\(slot)"
                )
            }
        }
    }

    /// The expanded slot is the compact one WHEREVER the compact one is not a figure
    /// — i.e. the two ladders differ by exactly the rung the handoff says they do.
    func testTheTwoSlotsDifferByExactlyTheFigureRung() {
        for status in LiveActivityRideStatus.allCases {
            for progress in [nil, 0.38, 1.0] as [Double?] {
                let resolved = card(status, progress: progress)
                if case .figure = resolved.compact { continue }
                XCTAssertEqual(
                    resolved.compact,
                    resolved.expandedTrailing,
                    "\(status) at \(String(describing: progress))"
                )
            }
        }
    }

    /// **THE ARRIVAL BEAT IS ONCE-ONLY, AND THIS IS THE PURE HALF OF THE PROOF.**
    ///
    /// The view animates on CHANGES to the values it is handed
    /// (`RideActivityRing.swift` keys every one of them to the resolved slot, never
    /// to `onAppear`). So the property that makes a re-push harmless is a property of
    /// THIS type: the ticker re-pushing the same terminal frame must resolve to an
    /// EQUAL card at any later moment, leaving SwiftUI nothing to animate a second
    /// time.
    ///
    /// `now` moves a full five minutes — the whole `completed` linger — because that
    /// is exactly what the server does: the same content state, pushed again, against
    /// a later clock. The other half of the proof is on the simulator
    /// (`RideActivityIslandUITests.testTheArrivalBeatDoesNotReplayOnARepush`).
    func testARepushOfTheSameTerminalFrameResolvesToAnIdenticalCard() {
        for status in [LiveActivityRideStatus.completed, .arrived] {
            let first = card(status, eta: nil, progress: 1, now: eta)
            let repushed = card(status, eta: nil, progress: 1, now: eta.addingTimeInterval(5 * 60))
            XCTAssertEqual(rendered(first), rendered(repushed), "\(status)")
            XCTAssertEqual(first.isStale, repushed.isStale, "\(status)")
        }
    }

    /// The beat's trigger is the SLOT, so the transition it plays on is a real one:
    /// the frame before an arrival is not a glyph and the frame after it is.
    func testTheGlyphIsReachedByATransitionRatherThanBySittingThere() {
        XCTAssertEqual(card(.accepted, eta: nil, progress: 0.88).expandedTrailing, .ringDeterminate(0.88))
        XCTAssertEqual(card(.arrived, eta: nil, progress: 1).expandedTrailing, .glyph(.wave))
        XCTAssertEqual(card(.enroute, eta: nil, progress: 0.9).expandedTrailing, .ringDeterminate(0.9))
        XCTAssertEqual(card(.completed, eta: nil, progress: 1).expandedTrailing, .glyph(.check))
    }

    // MARK: - 8. The monotone hold and the leg reset (unchanged by v3)

    func testWithinOneLegTheFractionNeverGoesDown() {
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.41, currentLeg: .dropoff, previous: 0.62, previousLeg: .dropoff),
            0.62
        )
    }

    func testWithinOneLegAHigherFractionIsAdopted() {
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.8, currentLeg: .dropoff, previous: 0.62, previousLeg: .dropoff),
            0.8
        )
    }

    func testWithinOneLegAMissingFractionCarriesTheLastOneForward() {
        XCTAssertEqual(
            RideActivityProgress.held(current: nil, currentLeg: .pickup, previous: 0.34, previousLeg: .pickup),
            0.34
        )
    }

    /// Leg one ends at exactly 1 and leg two opens near 0, so a max taken ACROSS the
    /// flip would pin the drop-off rail at full for the entire ride.
    func testTheLegIsTheResetKeyAndNothingSurvivesTheFlip() {
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.04, currentLeg: .dropoff, previous: 1, previousLeg: .pickup),
            0.04
        )
    }

    /// A leg flip with no fraction YET is the board's own idle rail, not a held full
    /// one — the second half of "the leg flip is the only backward move allowed".
    func testALegFlipWithNoFractionYetIsTheIdleRail() {
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: .dropoff, previous: 1, previousLeg: .pickup)
        )
    }

    func testALegThatBecomesNilDropsTheFraction() {
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: nil, previous: 0.62, previousLeg: .dropoff)
        )
    }

    func testTheFirstFrameOfAnActivityHoldsNothing() {
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: .pickup, previous: nil, previousLeg: nil)
        )
    }

    // MARK: - 9. The hold, through the shipping state machine

    func testTheStateMachineCarriesAPushedFractionForwardOntoItsOwnFrames() {
        let previous = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: Self.vehicleNickname,
            destination: Self.destination,
            progress: 0.62
        )

        let next = RideActivityStateMachine.contentState(
            for: enrouteRecord,
            vehicleName: Self.vehicleNickname,
            previous: previous
        )

        XCTAssertEqual(next.progress, 0.62)
        XCTAssertEqual(next.eta, 1_785_535_200, "the ETA carries forward for the same reason")
    }

    func testTheStateMachineNeverInventsAFractionFromTheAppsOwnTrackProgress() {
        var record = enrouteRecord
        record.trackProgress = 0.8

        let frame = RideActivityStateMachine.contentState(
            for: record,
            vehicleName: Self.vehicleNickname,
            previous: nil
        )

        XCTAssertNil(frame.progress)
    }

    /// The ending frame drops the fraction it inherited — and in v3 that renders as
    /// the IDLE rail rather than as no rail, which is the one thing about this rule
    /// the redesign changed downstream of it.
    func testTheCancelledEndingFrameDropsTheFractionAndRendersTheIdleRail() {
        let live = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: Self.vehicleNickname,
            destination: Self.destination,
            progress: 0.62
        )

        let ending = live.with(status: .cancelled)

        XCTAssertEqual(ending.status, .cancelled)
        XCTAssertNil(ending.progress, "no fraction on the ending frame")
        XCTAssertEqual(
            RideActivityCard.resolve(state: ending, vehicle: Self.vehicle, isStale: false).rail,
            .idle
        )
    }

    // MARK: - Helpers

    private static func text(of headline: RideActivityHeadline) -> String? {
        switch headline {
        case .pickupCountdown(let figure):
            return "\(RideActivityCopy.pickupPhase) \(RideActivityCopy.countdownJoin) \(figure.text)"
        case .dropoffClock(let clock):
            return "\(clock) \(RideActivityCopy.dropoffWord)"
        case .sentence(let text):
            return text
        }
    }

    private static func text(of compact: RideActivityTrailingSlot) -> String? {
        if case .figure(let figure) = compact { return figure }
        return nil
    }

    // MARK: - Fixtures

    private var enrouteRecord: RideRequestRecord {
        var record = RideRequestRecord(
            id: "ride-1",
            input: RideRequestInput(
                pickup: RidePlace(
                    id: "pickup",
                    label: "Sansome & Clay",
                    subtitle: nil,
                    miles: 0,
                    minutes: 0,
                    icon: "location.fill",
                    coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
                ),
                destination: RidePlace(
                    id: "dest",
                    label: RideActivityCardTests.destination,
                    subtitle: nil,
                    miles: 4.2,
                    minutes: 12,
                    icon: "house.fill",
                    coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
                ),
                fleetMemberID: "vehicle-1"
            ),
            status: .enroute
        )
        record.status = .enroute
        return record
    }
}

private extension LiveActivityRideStatus {
    /// Every member this build knows, plus one it does not — the sweeps above have
    /// to cover the `unrecognized` arm, and a generated enum with an
    /// associated-value catch-all has no synthesized `CaseIterable`.
    static var allCases: [LiveActivityRideStatus] {
        [
            .requested, .accepted, .arrived, .enroute,
            .completed, .declined, .cancelled, .reservationExpired,
            .unrecognized("boarding"),
        ]
    }
}
