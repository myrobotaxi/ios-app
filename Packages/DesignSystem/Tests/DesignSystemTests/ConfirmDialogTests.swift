import XCTest
import SwiftUI
import UIKit
@testable import DesignSystem

// MARK: - MYR-360 — the THIRD action, added ADDITIVELY
//
// `MRTConfirmDialogConfig` carried exactly two actions (confirm + dismiss) until
// MYR-360, whose pause warning genuinely has three answers: decline the
// reservations and pause, pause anyway, keep sharing. None of them is a variant of
// another, and forking a three-button dialog for the one screen that needs one
// would break "Reuse, don't fork" (CLAUDE.md) and split the app's confirm grammar
// permanently.
//
// So the third action is OPTIONAL, and the hard requirement is that every existing
// two-action dialog is untouched. That is asserted here as a MEASUREMENT rather
// than as a promise: a nil secondary must cost exactly zero points, which is only
// true if an absent optional view is neither laid out nor spaced by the enclosing
// `VStack(spacing: 8)`.
final class ConfirmDialogTests: XCTestCase {

    // MARK: Harness

    /// Hosts the real card at the dialog's own width and returns its measured size.
    /// The card is `.frame(maxWidth: 300)` + a 24pt page gutter, so a 393pt design
    /// canvas is the honest proposal.
    @MainActor
    private func measure(_ config: MRTConfirmDialogConfig) -> CGSize {
        let host = UIHostingController(rootView: MRTConfirmDialogCard(config: config, dismiss: {}))
        host.view.backgroundColor = .clear
        return host.sizeThatFits(in: CGSize(width: 393, height: CGFloat.greatestFiniteMagnitude))
    }

    /// The card RASTERIZED at 1x — the ground truth for "byte-identical".
    /// Returns the raw RGBA bytes plus the geometry needed to slice rows.
    @MainActor
    private func render(_ config: MRTConfirmDialogConfig) -> (bytes: [UInt8], width: Int, height: Int, stride: Int) {
        render(MRTConfirmDialogCard(config: config, dismiss: {}))
    }

    @MainActor
    private func render<V: View>(_ card: V) -> (bytes: [UInt8], width: Int, height: Int, stride: Int) {
        let renderer = ImageRenderer(
            content: card
                .frame(width: 393)
                .background(Color.black)
        )
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return ([], 0, 0, 0) }
        let width = cgImage.width
        let height = cgImage.height
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, width, height, stride)
    }

    /// The pixel rows `[from, to)` of a rendered card.
    private func rows(
        _ image: (bytes: [UInt8], width: Int, height: Int, stride: Int),
        _ from: Int,
        _ to: Int
    ) -> ArraySlice<UInt8> {
        image.bytes[(from * image.stride)..<(min(to, image.height) * image.stride)]
    }

    private func twoActionConfig() -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "calendar",
            title: "Pause ride sharing?",
            message: "A message.",
            actionLabel: "Confirm",
            dismissLabel: "Keep sharing",
            action: {}
        )
    }

    private func threeActionConfig() -> MRTConfirmDialogConfig {
        MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "calendar",
            title: "Pause ride sharing?",
            message: "A message.",
            actionLabel: "Confirm",
            secondaryLabel: "Pause anyway",
            secondaryAction: {},
            dismissLabel: "Keep sharing",
            action: {}
        )
    }

    // MARK: The additive contract

    /// The default-nil initializer parameters are what keep every existing call site
    /// compiling unchanged — this file is one of those call sites (the config is
    /// built with no secondary at all, positionally identical to the pre-MYR-360
    /// signature).
    func testSecondaryActionIsAbsentByDefault() {
        let config = twoActionConfig()
        XCTAssertNil(config.secondaryLabel, "a dialog built the old way carries no third action")
        XCTAssertNil(config.secondaryAction)
    }

    /// THE STRONGEST FORM OF THE BYTE-IDENTICAL PROOF: with `secondaryLabel` nil the
    /// card RASTERIZES to the same bytes as one built the pre-MYR-360 way. Not
    /// "about the same height" — the same pixels.
    ///
    /// It also pins the rule that the LABEL is what renders the button: a secondary
    /// ACTION with no label is a deliberate no-op, not an invisible tap target.
    @MainActor
    func testANilSecondaryRendersByteIdenticalPixels() {
        var withAction = twoActionConfig()
        withAction.secondaryAction = {}

        let plain = render(twoActionConfig())
        let unlabelled = render(withAction)

        XCTAssertGreaterThan(plain.height, 0, "the card must actually rasterize")
        XCTAssertEqual(plain.height, unlabelled.height)
        XCTAssertEqual(plain.width, unlabelled.width)
        XCTAssertEqual(plain.bytes, unlabelled.bytes, "an unlabelled secondary must not change one pixel")
    }

    /// THE BYTE-IDENTICAL PROOF. A nil secondary adds nothing; a non-nil one adds
    /// EXACTLY one 46pt button plus the stack's own 8pt spacing, and nothing else.
    /// If SwiftUI were spacing the absent optional view, or if the change had moved
    /// any other metric, this difference would not be the button's own height.
    @MainActor
    func testTheSecondaryButtonCostsExactlyOneButtonAndOneGap() {
        let two = measure(twoActionConfig()).height
        let three = measure(threeActionConfig()).height

        XCTAssertEqual(
            three - two,
            MRTButtonSize.md.height + 8,
            accuracy: 0.5,
            "the third action is one md button and one 8pt VStack gap — no other metric moves"
        )
        XCTAssertEqual(
            measure(twoActionConfig()).width,
            measure(threeActionConfig()).width,
            accuracy: 0.5,
            "the card's width is the dialog's own 300 cap in both shapes"
        )
    }

    /// ORDER IS THE GRAMMAR: the recommended action first, the alternative second,
    /// the way out last. Proven geometrically rather than by reading the source —
    /// everything above the last button is unchanged, and the LAST band (the dismiss
    /// button plus the card's 20pt bottom padding) is BYTE-EXACT. The only place the
    /// new button can be is between them.
    ///
    /// The upper region is compared with a ±1 tolerance and the number of affected
    /// rows is pinned: `ImageRenderer` antialiases the icon circle's edge one level
    /// differently across two canvas heights (measured: 1 row of 195, max delta 1 of
    /// 255). Everything structural — every glyph, every fill, every radius — is
    /// identical, and the tight bounds are what keep this a real guard rather than a
    /// tolerance to hide behind.
    @MainActor
    func testTheSecondaryButtonIsInsertedBetweenConfirmAndDismiss() {
        let two = render(twoActionConfig())
        let three = render(threeActionConfig())
        let button = Int(MRTButtonSize.md.height)
        // The dismiss button plus the card's own 20pt bottom padding — the band the
        // LAST action occupies.
        let lastBand = button + 20

        XCTAssertEqual(three.height, two.height + button + 8, "one button and one 8pt gap taller")

        var changedRows = 0
        var maxDelta = 0
        for row in 0..<(two.height - lastBand) {
            let a = Array(rows(two, row, row + 1))
            let b = Array(rows(three, row, row + 1))
            if a != b { changedRows += 1 }
            for index in a.indices { maxDelta = max(maxDelta, abs(Int(a[index]) - Int(b[index]))) }
        }
        XCTAssertLessThanOrEqual(maxDelta, 1, "icon, title, message and the confirm button are untouched")
        XCTAssertLessThanOrEqual(changedRows, 1, "and only one antialiased row differs at all")

        XCTAssertEqual(
            Array(rows(two, two.height - lastBand, two.height)),
            Array(rows(three, three.height - lastBand, three.height)),
            "the dismiss button is still the last thing on the card — byte for byte"
        )
    }

    // MARK: The content slot (MYR-360)

    /// THE SLOT'S BYTE-IDENTICAL PROOF. A card whose content slot is `EmptyView`
    /// rasterizes to the same bytes as one built with no slot at all.
    ///
    /// This is the trap the check in the card exists for: a bare `EmptyView`
    /// contributes no layout child, but `EmptyView().padding(.top, 14)` is a
    /// zero-sized view WITH 14pt of padding — which would silently move the action
    /// stack of every dialog in the app.
    @MainActor
    func testAnEmptyContentSlotRendersByteIdenticalPixels() {
        let plain = render(twoActionConfig())
        let slotted = render(
            MRTConfirmDialogCard(config: twoActionConfig(), dismiss: {}, dialogContent: { EmptyView() })
        )

        XCTAssertGreaterThan(plain.height, 0, "the card must actually rasterize")
        XCTAssertEqual(plain.height, slotted.height)
        XCTAssertEqual(plain.bytes, slotted.bytes, "an unused content slot must not change one pixel")
    }

    /// A slot that IS used sits between the message and the action stack, and costs
    /// exactly its own height plus the 14pt that separates it from the message.
    /// Proven geometrically: everything above the message is untouched, and the
    /// whole action stack (three buttons + the card's 20pt bottom padding) is
    /// byte-exact.
    @MainActor
    func testAUsedContentSlotSitsBetweenTheMessageAndTheActions() {
        let plain = render(threeActionConfig())
        let slotHeight = 40
        let slotted = render(
            MRTConfirmDialogCard(config: threeActionConfig(), dismiss: {}) {
                Color.red.frame(height: CGFloat(slotHeight))
            }
        )
        let actionBand = Int(MRTButtonSize.md.height) * 3 + 8 * 2 + 20

        XCTAssertEqual(slotted.height, plain.height + slotHeight + 14, "the slot plus its 14pt lead-in, and nothing else")
        XCTAssertEqual(
            Array(rows(plain, 0, plain.height - actionBand - 18)),
            Array(rows(slotted, 0, plain.height - actionBand - 18)),
            "icon, title and message are untouched by the slot"
        )
        var changedRows = 0
        var maxDelta = 0
        for row in 0..<actionBand {
            let a = Array(rows(plain, plain.height - actionBand + row, plain.height - actionBand + row + 1))
            let b = Array(rows(slotted, slotted.height - actionBand + row, slotted.height - actionBand + row + 1))
            if a != b { changedRows += 1 }
            for index in a.indices { maxDelta = max(maxDelta, abs(Int(a[index]) - Int(b[index]))) }
        }
        // Compared with a ±1 tolerance and a pinned row count, for the same reason
        // the third-action test is: `ImageRenderer` antialiases a rounded edge one
        // level differently across two canvas heights (measured: 3 rows of 174,
        // max delta 1 of 255). Every glyph, fill and radius is identical.
        XCTAssertLessThanOrEqual(maxDelta, 1, "and the three-button stack is still the last thing on the card")
        XCTAssertLessThanOrEqual(changedRows, 3, "…with only antialiasing between them")
    }

    /// The card is still capped at the dialog's documented anatomy (radius 22,
    /// max width 300, 46pt icon) with three buttons in it — the new action sits
    /// inside the established grammar rather than widening it.
    @MainActor
    func testTheThreeActionCardKeepsTheDialogAnatomy() {
        XCTAssertEqual(MRTMetrics.dialogMaxWidth, 300)
        XCTAssertEqual(MRTMetrics.dialogRadius, 22)
        XCTAssertEqual(MRTMetrics.dialogIconSize, 46)
        XCTAssertLessThanOrEqual(
            measure(threeActionConfig()).width,
            MRTMetrics.dialogMaxWidth + MRTMetrics.pageGutter * 2,
            "three buttons must not push the card past its own cap"
        )
    }
}
