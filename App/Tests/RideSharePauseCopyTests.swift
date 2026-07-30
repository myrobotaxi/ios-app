import XCTest
import UIKit
import SwiftUI
import DesignSystem
@testable import MyRoboTaxi

// MARK: - MYR-360 — the pause warning's copy and rows are MEASURED, not guessed
//
// The dialog card is capped at `MRTMetrics.dialogMaxWidth` (300) and pads its
// content 20pt on each side, so everything inside it — the message AND the
// reservation rows — lays out against 260pt. The card also has to fit the SHORTEST
// supported screen while carrying a 46pt icon, a 17pt title, the message, the row
// list, and — new in this issue — THREE buttons instead of two.
//
// The display cap is what that budget buys, so it is derived here rather than
// asserted as a preference. Same precedent as `VehicleControlTileCaptionTests`
// (MYR-335): a copy decision with a measurement behind it, against the worst case
// rather than a convenient example.
//
// THE ROWS EXIST BECAUSE THE PROSE DID NOT WORK. The first build listed the
// reservations as centred lines inside the message; the client's verdict was
// "list in plain text is not helpful". A list is a list because its parts line up.
final class RideSharePauseCopyTests: XCTestCase {

    // MARK: Geometry

    /// The card's content width: the dialog cap less its own 20pt padding on both
    /// sides. Everything in the card — message and rows — lays out against this.
    private static let contentWidth = MRTMetrics.dialogMaxWidth - 20 * 2

    /// The shortest screen this app ships to (iPhone SE, 667pt tall — the smallest
    /// iPhone above the iOS 17 deployment target, portrait-only).
    private static let shortestScreenHeight: CGFloat = 667

    /// `MRTConfirmDialogCard`'s message font (13pt regular).
    private static let messageFont = UIFont.systemFont(ofSize: 13)
    /// `RideSharePauseReservationList`'s two row fonts (14 medium over 11 regular),
    /// the `ViewerRow`/`PendingRow` grammar this list reuses.
    private static let rowPrimaryFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    private static let rowSecondaryFont = UIFont.systemFont(ofSize: 11)
    /// The width a row's TEXT gets: the content width less the 16pt glyph column and
    /// the 12pt gap beside it.
    private static let rowTextWidth = contentWidth - 16 - 12

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func height(_ text: String, font: UIFont = messageFont, width: CGFloat = contentWidth) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
    }

    private func width(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func reservation(_ name: String?, _ date: Date) -> UpcomingReservation {
        UpcomingReservation(id: UUID().uuidString, riderFirstName: name, scheduledFor: date)
    }

    /// The WORST CASE the rows can produce, and it is not a hypothetical: a
    /// reservation the server could not name, on a two-digit date, in a month whose
    /// abbreviation is long, at a two-digit hour with a two-digit minute.
    private func worstCaseReservations(count: Int, now: Date) -> [UpcomingReservation] {
        let calendar = Self.calendar
        return (0..<count).map { index in
            let day = calendar.date(byAdding: .day, value: 22 + index, to: now) ?? now
            let stamp = calendar.date(bySettingHour: 11, minute: 45, second: 0, of: day) ?? day
            return reservation(nil, stamp)
        }
    }

    // MARK: The rows

    /// The row's two lines, verbatim: the shared day-and-time stamp over the rider's
    /// first name. No "Pickup" prefix, no em-dash run-on — that was the prose shape.
    func testARowIsADayAndTimeOverAName() {
        let now = Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 9))!
        let pickup = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 17, minute: 30))!
        let row = reservation("Alex", pickup)

        XCTAssertEqual(
            RideSharePauseDialog.rowTime(for: row, now: now, calendar: Self.calendar),
            "Sun, Aug 2 \u{00B7} 5:30 PM"
        )
        XCTAssertEqual(RideSharePauseDialog.rowRider(for: row), "Alex")
    }

    /// THE MEASUREMENT BEHIND THE CAP. Neither row line wraps at the width the card
    /// gives it — not even in the worst case — so a row is exactly two lines and the
    /// cap can be reasoned about as rows rather than as rendered lines. This is the
    /// property the prose version did not have.
    func testNoRowLineWrapsEvenInTheWorstCase() {
        let now = Date()
        for row in worstCaseReservations(count: 5, now: now) {
            let time = RideSharePauseDialog.rowTime(for: row, now: now, calendar: Self.calendar)
            let rider = RideSharePauseDialog.rowRider(for: row)
            XCTAssertLessThanOrEqual(
                width(time, font: Self.rowPrimaryFont), Self.rowTextWidth,
                "\"\(time)\" is \(width(time, font: Self.rowPrimaryFont))pt against \(Self.rowTextWidth)pt"
            )
            XCTAssertLessThanOrEqual(width(rider, font: Self.rowSecondaryFont), Self.rowTextWidth)
        }
        XCTAssertEqual(RideSharePauseDialog.displayCap, 3)
    }

    /// A long real first name still fits — the row's own upper bound, and the reason
    /// the secondary line is a separate line rather than a suffix.
    func testALongFirstNameStillFitsARow() {
        for name in ["Alex", "Christopher", "Bartholomew", "A rider"] {
            XCTAssertLessThanOrEqual(
                width(name, font: Self.rowSecondaryFont), Self.rowTextWidth,
                "\"\(name)\" would truncate in a row"
            )
        }
    }

    /// Everything past the cap is COUNTED, never dropped — the owner is told the
    /// size of what they are deciding about even where the card has no room to name
    /// it. And nothing rolls up when nothing is hidden.
    func testTheRollupCountsEverythingPastTheCap() {
        let now = Date()
        XCTAssertEqual(RideSharePauseDialog.overflowLabel(for: worstCaseReservations(count: 9, now: now)), "+6 more")
        XCTAssertEqual(RideSharePauseDialog.overflowLabel(for: worstCaseReservations(count: 4, now: now)), "+1 more")
        XCTAssertNil(RideSharePauseDialog.overflowLabel(for: worstCaseReservations(count: 3, now: now)))
        XCTAssertNil(RideSharePauseDialog.overflowLabel(for: []))
    }

    // MARK: The message

    /// The message is ONE sentence now that the reservations have their own rows —
    /// and it names nobody and states no time, because those are the rows' job.
    func testTheMessageIsTheConsequenceAndNothingElse() {
        XCTAssertEqual(
            RideSharePauseDialog.message,
            "Paused rides won\u{2019}t be dispatched \u{2014} they expire 30 minutes after pickup time."
        )
        for word in RideSharePauseDialog.message.components(separatedBy: .whitespacesAndNewlines) where !word.isEmpty {
            XCTAssertLessThanOrEqual(
                width(word, font: Self.messageFont), Self.contentWidth,
                "\"\(word)\" would truncate in a \(Self.contentWidth)pt message box"
            )
        }
        XCTAssertLessThanOrEqual(
            height(RideSharePauseDialog.message), 60,
            "the sentence stays inside three 13pt lines"
        )
    }

    // MARK: The whole card

    /// THE CARD FITS THE SHORTEST SCREEN with the worst-case list AND three buttons.
    ///
    /// The card's own shape is measured directly in DesignSystem's
    /// `ConfirmDialogTests`; what is measured HERE is the part this issue owns — the
    /// message plus the row list — against the height the rest of the anatomy leaves
    /// it. The anatomy is the documented one: 20pt card padding top and bottom, the
    /// 46pt icon circle, 14pt to the title, the title's own 17pt line, 6pt to the
    /// message, 14pt to the list, 18pt below it, then three 46pt buttons with two
    /// 8pt gaps.
    @MainActor
    func testTheWorstCaseListFitsTheRoomTheCardLeavesIt() {
        let now = Date()
        let list = RideSharePauseReservationList(
            reservations: worstCaseReservations(count: 9, now: now),
            now: now,
            calendar: Self.calendar
        )
        let host = UIHostingController(rootView: list)
        let listHeight = host.sizeThatFits(
            in: CGSize(width: Self.contentWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height

        let chrome: CGFloat = 20 + MRTMetrics.dialogIconSize + 14 + 21 + 6
            + 14 + 18 + (MRTButtonSize.md.height * 3 + 8 * 2) + 20
        let used = chrome + height(RideSharePauseDialog.message) + listHeight

        XCTAssertGreaterThan(listHeight, 0, "the list must actually lay out")
        XCTAssertLessThanOrEqual(
            used, Self.shortestScreenHeight - 80,
            "the worst-case card is \(used)pt against a 667pt screen (list alone: \(listHeight)pt)"
        )
    }

    /// The cap is a HARD cap: whatever the list holds, exactly `displayCap` rows are
    /// named. This is the guard that keeps the measurement above meaningful.
    @MainActor
    func testExactlyDisplayCapRowsAreEverNamed() {
        let now = Date()
        let many = worstCaseReservations(count: 9, now: now)
        let three = worstCaseReservations(count: 3, now: now)
        let host = { (rs: [UpcomingReservation]) -> CGFloat in
            UIHostingController(
                rootView: RideSharePauseReservationList(reservations: rs, now: now, calendar: Self.calendar)
            ).sizeThatFits(in: CGSize(width: Self.contentWidth, height: CGFloat.greatestFiniteMagnitude)).height
        }
        // 9 reservations renders 3 rows + a rollup; 3 renders 3 rows and no rollup.
        // So the 9-row list is TALLER by exactly one rollup row + one hairline, and
        // never by six more rows.
        XCTAssertLessThan(host(many) - host(three), 60, "a 9-item list is 3 rows plus a rollup, not 9 rows")
        XCTAssertGreaterThan(host(many) - host(three), 0, "…and the rollup really is rendered")
    }

    // MARK: The same-day branch

    /// A reservation later TODAY is a real case — and the shared formatter's
    /// same-calendar-day branch returns the TIME ALONE, which in a list of dated rows
    /// reads as an omission. The day word is supplied.
    func testAReservationLaterTodayStillReadsAsADate() {
        let now = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 9))!
        let pickup = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 17, minute: 30))!

        XCTAssertEqual(
            VehicleServiceWindow.completionLabel(for: pickup, now: now, calendar: Self.calendar),
            "5:30 PM",
            "the shared formatter's same-day branch is time-only (that is why this test exists)"
        )
        XCTAssertEqual(
            RideSharePauseDialog.rowTime(for: reservation("Alex", pickup), now: now, calendar: Self.calendar),
            "Today \u{00B7} 5:30 PM"
        )
    }

    /// ONE formatter, still. The stamp in this dialog is byte-identical to the one
    /// the owner's service-completion line renders for the same instant, because it
    /// IS that function — no second formatter was written for this surface.
    func testTheStampComesFromTheOneSharedFormatter() {
        let now = Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 9))!
        let pickup = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 17, minute: 30))!
        let shared = VehicleServiceWindow.completionLabel(for: pickup, now: now, calendar: Self.calendar)!

        XCTAssertEqual(
            RideSharePauseDialog.rowTime(for: reservation("Alex", pickup), now: now, calendar: Self.calendar),
            shared
        )
    }

    // MARK: The labels

    func testTheActionLabelPluralises() {
        XCTAssertEqual(RideSharePauseDialog.actionLabel(count: 1), "Decline it and pause")
        XCTAssertEqual(RideSharePauseDialog.actionLabel(count: 2), "Decline them and pause")
        XCTAssertEqual(RideSharePauseDialog.actionLabel(count: 9), "Decline them and pause")
    }

    /// Every button label fits its 46pt-tall md button at the button's own type
    /// scale, inside the 260pt card content width — so no action ellipsizes.
    func testEveryButtonLabelFitsTheDialogButton() {
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let labels = [
            RideSharePauseDialog.actionLabel(count: 1),
            RideSharePauseDialog.actionLabel(count: 2),
            RideSharePauseDialog.secondaryLabel,
            RideSharePauseDialog.dismissLabel
        ]
        for label in labels {
            XCTAssertLessThanOrEqual(
                width(label, font: font), Self.contentWidth,
                "\"\(label)\" is \(width(label, font: font))pt against a \(Self.contentWidth)pt button"
            )
        }
    }

    /// The internal role term must never reach this surface.
    func testTheInternalRoleTermNeverReachesTheDialog() {
        XCTAssertEqual(RideSharePauseDialog.unnamedRider, "A rider")
        XCTAssertEqual(IncomingRequestDisplay.neutralRole, "Shared viewer")
        XCTAssertNotEqual(RideSharePauseDialog.unnamedRider, IncomingRequestDisplay.neutralRole)

        let now = Date()
        let strings = [RideSharePauseDialog.message, RideSharePauseDialog.title,
                       RideSharePauseDialog.secondaryLabel, RideSharePauseDialog.dismissLabel]
            + worstCaseReservations(count: 4, now: now).flatMap {
                [RideSharePauseDialog.rowTime(for: $0, now: now, calendar: Self.calendar),
                 RideSharePauseDialog.rowRider(for: $0)]
            }
            + [RideSharePauseDialog.overflowLabel(for: worstCaseReservations(count: 4, now: now)) ?? ""]
        for text in strings {
            XCTAssertFalse(text.contains("Shared viewer"), "\"\(text)\" carries the internal role term")
        }
    }

    /// The new notice's tile token is measured with the rest of the catalog in
    /// `VehicleCommandNoticeTests`; here we pin what it SAYS, because the sentence
    /// is the part an owner acts on.
    func testTheDeclineFailureNoticeNamesTheRestingState() {
        XCTAssertEqual(
            VehicleCommandNotice.reservationNotDeclined.message,
            "Couldn\u{2019}t decline a ride \u{2014} still sharing"
        )
        XCTAssertEqual(VehicleCommandNotice.reservationNotDeclined.tileText, "Still on")
        XCTAssertNil(VehicleCommandNotice.reservationNotDeclined.action, "there is nothing in-app to route to")
        XCTAssertFalse(VehicleCommandNotice.reservationNotDeclined.isTransient, "it is a settled report, not a phase")
    }
}
