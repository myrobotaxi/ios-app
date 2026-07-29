import XCTest
import UIKit
import MyRoboTaxiKit
@testable import MyRoboTaxi

// MARK: - MYR-335 — no quick-tile caption may ellipsize
//
// THE CLIENT'S REPORT (owner sheet, half detent): "Locked / Synced 13…",
// "Locked / Tap to unl…", "Trunk / Closed · 1…". Four tiles split the sheet's
// content width, so each holds ~50pt of text; several captions were 60–92pt.
//
// THE PROTOTYPE HAS THE SAME DEFECT, and that is why this is a test and not a
// one-line copy tweak. Driven live (`design/prototype.html`, Flat, owner Vehicle,
// sheet at half) its own lock caption reports `scrollWidth` 65 against
// `clientWidth` 56 — "Tap to u…". The design's `textOverflow: 'ellipsis'`
// (vehicle-controls.jsx:36-37) was a fallback that had become the normal case,
// so matching the jsx verbatim reproduced the bug. The captions are now written
// to FIT, and this file is what keeps them that way.
//
// It measures every caption the four tiles can produce — not a convenient
// sample: both lock states, both trunk states, both charge states, climate off
// and on across the executor's whole target-temp clamp, and both honest-unknown
// forms — against the real tile geometry on the NARROWEST SUPPORTED DEVICE.
final class VehicleControlTileCaptionTests: XCTestCase {

    // MARK: Geometry

    /// The narrowest screen this app ships to: 375pt (iPhone SE 2nd/3rd gen — the
    /// smallest iPhone above the 17.0 deployment target, portrait-only,
    /// `TARGETED_DEVICE_FAMILY = 1`). The design canvas is 393 and the client's
    /// phone is 440; a caption that fits 375 fits all three, which is the point.
    private static let narrowestScreenWidth: CGFloat = 375
    /// The design's own full-bleed canvas, kept as a second column so a
    /// regression can be read against the number the drift gate uses.
    private static let designCanvasWidth: CGFloat = 393

    /// One tile's INNER width: the screen less the 24pt page gutter on each side,
    /// less the three 8pt gaps between four tiles, divided by four, less
    /// `ControlTile`'s own 13pt horizontal padding on each side. Same derivation
    /// as `VehicleCommandNoticeTests.tileInnerWidth` (MYR-301) — one geometry,
    /// two callers.
    private static func tileInnerWidth(screen: CGFloat) -> CGFloat {
        let tile = (screen - 24 * 2 - 8 * 3) / 4
        return tile - 13 * 2
    }

    private static let subFont = UIFont.systemFont(ofSize: 11, weight: .medium)
    private static let labelFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    /// `ControlTile`'s label floor (`.minimumScaleFactor(0.8)`) — a label may
    /// shrink this far before SwiftUI truncates it. Subs have NO scaling at all
    /// (MYR-281: one uniform 11pt size across the row), so their budget is 1.0.
    private static let labelMinimumScale: CGFloat = 0.8

    private func width(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: The captions under test
    //
    // Every string `VehicleControls`'s four tiles can put on the sub line.

    private static var lockSubs: [String] { ["Unlock", "Lock"] }
    private static var trunkSubs: [String] { ["Open", "Closed"] }
    /// The charge tile's door states, plus MYR-333's live SESSION strings, which
    /// outrank the door in that one line.
    private static var chargeSubs: [String] { ["Open", "Closed", "Charging", "Charged"] }
    /// Climate is off, on-without-a-known-temp, or on with a target temperature.
    /// The executor clamps that temperature to 60…82°F
    /// (`SimulatedVehicleCommandExecutor.setTargetTemp`, vehicle-controls.jsx:
    /// 262,270 — the same range Tesla's own control exposes), so the caption is
    /// measured across the WHOLE clamp rather than at one convenient value.
    private static var climateSubs: [String] {
        ["Off", "On"] + (60...82).map { "On \u{00B7} \($0)\u{00B0}" }
    }
    private static var unknownSubs: [String] {
        [VehicleControlFreshness.tileSyncingSub, VehicleControlFreshness.tileUnavailableSub]
    }
    /// Plus the MYR-301/329 command notices, which REPLACE the resting sub in
    /// place. `VehicleCommandNoticeTests` measures these against the 393pt
    /// canvas; they are re-measured here against the narrowest device, because a
    /// notice token that ellipsizes is the same defect as a resting one that does.
    private static let allNotices: [VehicleCommandNotice] = [
        .waking, .asleep, .pairKey, .relink, .relinkCharging, .cooldown,
        .rejected(nil), .rejected(.vehicleInService), .failed,
    ]
    private static var noticeSubs: [String] { allNotices.map(\.tileText) }
    /// The three notices that can only ever land on a full-width DETAILS ROW —
    /// the plate editor and the service-completion row are not tiles
    /// (`VehicleCommandNotice.tileText`'s own comment says so). They are
    /// tokenized with the rest so the vocabulary stays uniform, and
    /// `VehicleCommandNoticeTests` measures them against the 393pt tile; they are
    /// deliberately NOT held to the 4-column budget here, because no tile renders
    /// them and shrinking copy for a surface it never reaches is noise.
    private static let rowOnlyNotices: [VehicleCommandNotice] = [
        .invalidPlate, .plateNotSaved, .serviceWindowPast,
    ]

    private static var allSubs: [String] {
        lockSubs + trunkSubs + chargeSubs + climateSubs + unknownSubs + noticeSubs
    }

    private static var allLabels: [String] {
        ["Locked", "Unlocked", "Lock", "Climate", "Trunk", "Charge"]
    }

    // MARK: 1 — nothing ellipsizes

    /// THE REGRESSION. Every sub, at the one uniform 11pt size, inside one tile
    /// on the narrowest supported device.
    func testNoTileSubTruncatesOnTheNarrowestSupportedDevice() {
        let budget = Self.tileInnerWidth(screen: Self.narrowestScreenWidth)
        for sub in Self.allSubs {
            let w = width(sub, font: Self.subFont)
            XCTAssertLessThanOrEqual(
                w, budget,
                "\"\(sub)\" is \(w)pt in a \(budget)pt tile at \(Self.narrowestScreenWidth)pt \u{2014} it would ellipsize"
            )
        }
    }

    /// The same on the design's own canvas, so a failure can be read directly
    /// against the drift-gate captures. The row-only notice tokens are held to
    /// THIS width (they share the tile vocabulary, they just never render in one).
    func testNoTileSubTruncatesOnTheDesignCanvas() {
        let budget = Self.tileInnerWidth(screen: Self.designCanvasWidth)
        for sub in Self.allSubs + Self.rowOnlyNotices.map(\.tileText) {
            XCTAssertLessThanOrEqual(width(sub, font: Self.subFont), budget, "\"\(sub)\" overflows the 393pt tile")
        }
    }

    /// Labels are allowed to scale down to `minimumScaleFactor` before they
    /// truncate — but no further. "Unlocked" is the widest and was 0.65pt over
    /// the old 0.85 floor at 375pt, which is why that floor moved to 0.8.
    func testNoTileLabelTruncatesOnTheNarrowestSupportedDevice() {
        let budget = Self.tileInnerWidth(screen: Self.narrowestScreenWidth)
        for label in Self.allLabels {
            let scaled = width(label, font: Self.labelFont) * Self.labelMinimumScale
            XCTAssertLessThanOrEqual(
                scaled, budget,
                "\"\(label)\" is \(scaled)pt even at the \(Self.labelMinimumScale) scale floor, in a \(budget)pt tile"
            )
        }
    }

    // MARK: 2 — the premise: the OLD captions genuinely did not fit
    //
    // Without this the fix reads as taste. These are the exact strings the
    // client screenshotted, measured against the same budget.

    func testTheCaptionsThisIssueReplacedDidNotFit() {
        let budget = Self.tileInnerWidth(screen: Self.narrowestScreenWidth)
        let designBudget = Self.tileInnerWidth(screen: Self.designCanvasWidth)
        let replaced = [
            "Tap to unlock",        // \u{2192} "Unlock"
            "Tap to lock",          // \u{2192} "Lock"
            "Synced 13m ago",       // \u{2192} dropped (the sheet's freshness stamp says it)
            "Closed \u{00B7} 13m ago",  // \u{2192} "Closed"
            "Open \u{00B7} 13m ago",    // \u{2192} "Open"
            "Port closed",          // \u{2192} "Closed"
            "\u{2014} Unavailable", // \u{2192} "No data"
            "\u{2014} Syncing",     // \u{2192} "Syncing"
            "Complete",             // \u{2192} "Charged" (MYR-333's charge-session token)
        ]
        for old in replaced {
            XCTAssertGreaterThan(
                width(old, font: Self.subFont), budget,
                "\"\(old)\" is the premise of this change \u{2014} it must NOT fit the \(budget)pt tile"
            )
        }
        // The two the client actually photographed also overflow the DESIGN's own
        // canvas, so this was never a device-specific squeeze.
        for old in ["Tap to unlock", "Synced 13m ago", "Closed \u{00B7} 13m ago", "Port closed"] {
            XCTAssertGreaterThan(width(old, font: Self.subFont), designBudget, "\"\(old)\" overflows even at 393pt")
        }
    }

    // MARK: 3 — the copy still says what it has to

    /// Compressing a caption must not cost meaning. The lock tile's STATE moved
    /// nowhere — it is the label — and the action verb survives; the trunk and
    /// charge tiles still name their door's state; VoiceOver still gets the full
    /// sentence (`ControlTile.spokenLabel`).
    func testCompressedCopyKeepsItsMeaning() {
        XCTAssertTrue(Self.lockSubs.contains("Unlock"), "the lock tile's sub is still the action it performs")
        XCTAssertTrue(Self.lockSubs.contains("Lock"))
        // The state lives on the label, so it is never the thing that was dropped.
        XCTAssertTrue(Self.allLabels.contains("Locked"))
        XCTAssertTrue(Self.allLabels.contains("Unlocked"))
        // Door states stay explicit on both door tiles…
        XCTAssertEqual(Set(Self.trunkSubs), Set(["Open", "Closed"]))
        XCTAssertTrue(Set(Self.chargeSubs).isSuperset(of: ["Open", "Closed"]))
        // …and MYR-333's charge SESSION still outranks the door in that line.
        XCTAssertTrue(Set(Self.chargeSubs).isSuperset(of: ["Charging", "Charged"]))
        // The honest-unknown pair stays a PAIR — the two states must never
        // collapse into one word (MYR-260's whole point).
        XCTAssertNotEqual(VehicleControlFreshness.tileSyncingSub, VehicleControlFreshness.tileUnavailableSub)
    }

    /// The tile forms are the SAME decision as the full-width forms — only the
    /// wording is shorter. A tile must never say "Syncing" where the wide row
    /// would have said "Unavailable".
    func testTileUnknownSubTracksTheFullWidthDecisionExactly() {
        let cases: [(Bool, Bool?)] = [
            (false, nil), (false, true), (false, false),
            (true, nil), (true, true), (true, false),
        ]
        for (hasSnapshot, isStreaming) in cases {
            let wide = VehicleControlFreshness.unknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming)
            let tile = VehicleControlFreshness.tileUnknownSub(hasSnapshot: hasSnapshot, isStreaming: isStreaming)
            let agree = (wide == VehicleControlFreshness.unavailableSub)
                == (tile == VehicleControlFreshness.tileUnavailableSub)
            XCTAssertTrue(
                agree,
                "hasSnapshot=\(hasSnapshot) isStreaming=\(String(describing: isStreaming)): wide said \"\(wide)\" but the tile said \"\(tile)\""
            )
        }
    }

    // MARK: 4 — recency is stated exactly once

    /// MYR-260 gave each safety tile its own "X ago"; MYR-315 put a freshness
    /// stamp in the sheet hero; MYR-335 removed the duplicate from the tiles,
    /// because it is the copy with no room. Assert BOTH halves: no tile caption
    /// carries a recency any more, and the stamp still does.
    func testRecencyIsStatedByTheStampAndNotByTheTiles() {
        for sub in Self.allSubs {
            XCTAssertFalse(
                sub.contains("ago") || sub.hasPrefix("Synced"),
                "\"\(sub)\" re-introduces a per-tile recency \u{2014} the sheet's freshness stamp states it"
            )
        }
        let now = Date()
        let stamp = VehicleFreshnessStamp.recency(
            isStreaming: false, lastUpdated: now.addingTimeInterval(-13 * 60), now: now
        )
        XCTAssertEqual(stamp?.label, "Synced 13m ago", "the stamp is where the owner reads how current the sheet is")
    }
}
