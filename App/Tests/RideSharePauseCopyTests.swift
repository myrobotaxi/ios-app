import XCTest
import UIKit
import SwiftUI
import DesignSystem
@testable import MyRoboTaxi

// MARK: - MYR-360 — the pause warning's copy is MEASURED, not guessed
//
// The dialog card is capped at `MRTMetrics.dialogMaxWidth` (300) and pads its
// content 20pt on each side, so every line of the message lays out against 260pt.
// The card also has to fit the SHORTEST supported screen while carrying a 46pt
// icon, a 17pt title, the message, and — new in this issue — THREE buttons instead
// of two.
//
// The display cap is what that budget buys, so it is derived here rather than
// asserted as a preference. Same precedent as `VehicleControlTileCaptionTests`
// (MYR-335): a copy decision with a measurement behind it, against the worst case
// rather than a convenient example.
final class RideSharePauseCopyTests: XCTestCase {

    // MARK: Geometry

    /// The message's layout width: the dialog cap less the card's own 20pt padding
    /// on both sides.
    private static let messageWidth = MRTMetrics.dialogMaxWidth - 20 * 2

    /// The shortest screen this app ships to (iPhone SE, 667pt tall — the smallest
    /// iPhone above the iOS 17 deployment target, portrait-only).
    private static let shortestScreenHeight: CGFloat = 667

    /// `MRTConfirmDialogCard`'s message font (13pt regular).
    private static let messageFont = UIFont.systemFont(ofSize: 13)

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// The rendered height of `text` wrapped at the message width.
    private func height(_ text: String) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: Self.messageWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.messageFont],
            context: nil
        ).height
    }

    private func reservation(_ name: String?, _ date: Date) -> UpcomingReservation {
        UpcomingReservation(
            id: UUID().uuidString,
            riderLabel: name ?? IncomingRequestDisplay.neutralRole,
            scheduledFor: date
        )
    }

    /// The WORST CASE the copy can produce, and it is not a hypothetical: a
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

    // MARK: The lines

    /// One reservation is ONE line at the design canvas for an ordinary first name —
    /// which is the common case and the shape the copy is written for.
    func testAnOrdinaryReservationLineFitsOnOneLine() {
        let now = Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 9))!
        let pickup = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 17, minute: 30))!
        let line = RideSharePauseDialog.line(
            for: reservation("Alex", pickup),
            now: now,
            calendar: Self.calendar
        )

        XCTAssertEqual(line, "Pickup Sat, Aug 2 \u{00B7} 5:30 PM \u{2014} Alex", "the issue's copy, verbatim")
        XCTAssertLessThanOrEqual(
            (line as NSString).size(withAttributes: [.font: Self.messageFont]).width,
            Self.messageWidth,
            "a named reservation fits one 260pt line"
        )
    }

    /// THE MEASUREMENT BEHIND THE CAP. The worst case WRAPS — a listed reservation
    /// is worth up to two rendered lines, not one — which is why the cap is two and
    /// not three.
    func testTheWorstCaseLineWrapsWhichIsWhyTheCapIsTwo() {
        let now = Date()
        let line = RideSharePauseDialog.line(
            for: worstCaseReservations(count: 1, now: now)[0],
            now: now,
            calendar: Self.calendar
        )
        let oneLineHeight = height("Pickup")

        XCTAssertGreaterThan(
            (line as NSString).size(withAttributes: [.font: Self.messageFont]).width,
            Self.messageWidth,
            "the nameless worst case does not fit one line — the cap must account for it"
        )
        XCTAssertLessThanOrEqual(
            height(line), oneLineHeight * 2 + 1,
            "…but it never exceeds two"
        )
        XCTAssertEqual(RideSharePauseDialog.displayCap, 2)
    }

    /// The whole message NEVER overflows its width: `Text` wraps, so the assertion
    /// that matters is that no single WORD is wider than the box (which would
    /// truncate) — including the rollup line and the consequence sentence.
    func testNoWordInTheMessageIsWiderThanTheDialog() {
        let now = Date()
        let message = RideSharePauseDialog.message(
            for: worstCaseReservations(count: 9, now: now),
            now: now,
            calendar: Self.calendar
        )
        for word in message.components(separatedBy: .whitespacesAndNewlines) where !word.isEmpty {
            let width = (word as NSString).size(withAttributes: [.font: Self.messageFont]).width
            XCTAssertLessThanOrEqual(
                width, Self.messageWidth,
                "\"\(word)\" is \(width)pt and would truncate in a \(Self.messageWidth)pt message box"
            )
        }
        XCTAssertTrue(message.contains("+7 more"), "everything past the cap is counted")
    }

    // MARK: The whole card

    /// THE CARD FITS THE SHORTEST SCREEN, with the worst-case message AND three
    /// buttons.
    ///
    /// The card's own shape is measured directly in DesignSystem's
    /// `ConfirmDialogTests` (which can host the private view); what is measured HERE
    /// is the part this issue owns — the MESSAGE — against the height the rest of
    /// the anatomy leaves it. The anatomy is the documented one: 20pt card padding
    /// top and bottom, the 46pt icon circle, 14pt to the title, the title's own
    /// 17pt line, 6pt to the message, 18pt below it, then three 46pt buttons with
    /// two 8pt gaps.
    func testTheWorstCaseMessageFitsTheRoomTheCardLeavesIt() {
        let now = Date()
        let message = RideSharePauseDialog.message(
            for: worstCaseReservations(count: 9, now: now),
            now: now,
            calendar: Self.calendar
        )
        let chrome: CGFloat = 20 + MRTMetrics.dialogIconSize + 14 + 21 + 6
            + 18 + (MRTButtonSize.md.height * 3 + 8 * 2) + 20
        let budget = Self.shortestScreenHeight - 80 - chrome

        XCTAssertGreaterThan(budget, 0)
        XCTAssertLessThanOrEqual(
            height(message), budget,
            "the worst-case message is \(height(message))pt against \(budget)pt of room on a 667pt screen"
        )
    }

    /// A THIRD button on the card, and a fourth pickup line, are not free — so the
    /// header room the message can spend is bounded rather than assumed. Adding one
    /// more listed reservation to the worst case must NOT be what makes it overflow;
    /// this is the guard that keeps a future cap bump honest.
    func testRaisingTheCapWouldHaveToBeRemeasured() {
        let now = Date()
        let two = RideSharePauseDialog.message(
            for: worstCaseReservations(count: 3, now: now), now: now, calendar: Self.calendar
        )
        let lines = two.components(separatedBy: "\n")
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("Pickup") }.count, RideSharePauseDialog.displayCap,
            "exactly `displayCap` reservations are named, whatever the list holds"
        )
        XCTAssertEqual(lines[RideSharePauseDialog.displayCap], "+1 more")
    }

    // MARK: The same-day branch

    /// A reservation later TODAY is a real case — and the shared formatter's
    /// same-calendar-day branch returns the TIME ALONE, which on a line that reads
    /// "Pickup 5:30 PM" would look like a duration. The day word is supplied.
    func testAReservationLaterTodayStillReadsAsAPickupTime() {
        let now = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 9))!
        let pickup = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 17, minute: 30))!

        XCTAssertEqual(
            VehicleServiceWindow.completionLabel(for: pickup, now: now, calendar: Self.calendar),
            "5:30 PM",
            "the shared formatter's same-day branch is time-only (that is why this test exists)"
        )
        XCTAssertEqual(
            RideSharePauseDialog.line(for: reservation("Alex", pickup), now: now, calendar: Self.calendar),
            "Pickup today \u{00B7} 5:30 PM \u{2014} Alex"
        )
    }

    /// ONE formatter, still. The stamp in this dialog is byte-identical to the one
    /// the owner's service-completion line renders for the same instant, because it
    /// IS that function — no second formatter was written for this surface.
    func testTheStampComesFromTheOneSharedFormatter() {
        let now = Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 9))!
        let pickup = Self.calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 17, minute: 30))!
        let shared = VehicleServiceWindow.completionLabel(for: pickup, now: now, calendar: Self.calendar)!

        XCTAssertTrue(
            RideSharePauseDialog.line(for: reservation("Alex", pickup), now: now, calendar: Self.calendar)
                .contains(shared)
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
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(
                width, Self.messageWidth,
                "\"\(label)\" is \(width)pt against a \(Self.messageWidth)pt button"
            )
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
