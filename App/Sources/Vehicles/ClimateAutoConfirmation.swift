import Foundation

// MARK: - ClimateAutoConfirmation (MYR-466) — Auto is a request, not a result
//
// External beta, build 202608030843. The owner, during a live ride: *"Change the
// climate to Auto mode and it did not register in car or change the mode in the
// car and then in the app it flipped right back to manual mode so it looks like
// this is not working."* His screenshot is the post-revert state — the segment
// back on **Cool** — and his LATER screenshots the same evening show Auto
// selected and holding, so the failure is intermittent rather than absolute.
//
// THE TRIAGE, in the order the issue asked for it:
//
//  1. **Is Auto a supported write?** Half. `VehicleCommand` carries
//     `auto_conditioning_start` / `auto_conditioning_stop` and nothing else for
//     climate, and Tesla's Fleet API has **no command that sets the HVAC's AUTO
//     MODE**. `auto_conditioning_start` is a POWER command: it turns the climate
//     system ON. On a car whose climate is already on and in manual
//     (`hvacAutoMode == Override`) it is very nearly a no-op — which is exactly
//     the condition his screenshot documents (the status chips read "Climate On ·
//     64°" with the mode on Cool). That is the intermittency: from OFF, starting
//     the HVAC brings it up in auto and the tap appears to work; from
//     manual-and-already-on, it does not.
//  2. **Is the command issued, and what does it return?** Issued, and it returns
//     **200 `applied`**. The car accepted a command to do something it was
//     already doing. There is no error anywhere on this path.
//  3. **Why is the failure silent?** Because on the client's terms there was no
//     failure. `setClimateMode` optimistically showed `.auto` on the ack and held
//     it for one settle window; when the window lapsed with the car still
//     reporting `Override`, `reconcileClimateMode` did precisely what it was
//     written to do — accepted the car's reported reality — and moved the segment
//     to Cool **with nothing said**. The owner-write-reverts shape of MYR-274 /
//     MYR-351, with the twist that here the revert is CORRECT and only the
//     silence is wrong.
//
// SO THE FIX IS NOT TO HOLD THE OPTIMISTIC VALUE HARDER. A control that springs
// back is bad; a control that lies about the car indefinitely is worse. What was
// missing is the third state between "it worked" and "it was refused": **the
// command was accepted and the car did not adopt it.** This type is that state,
// and the executor turns its `.notAdopted` verdict into an honest notice
// (`VehicleCommandNotice.autoNotAdopted`) beside the segment as it returns to the
// car's real mode.
//
// WHAT IS DELIBERATELY *NOT* DONE HERE:
//
//  • **No retry.** Re-sending `auto_conditioning_start` to a car that has already
//    applied it is the same no-op a second time, and a client that silently
//    retried would spend the §7.9 per-vehicle rate limit to produce the identical
//    frame.
//  • **No stop-then-start.** Cycling `auto_conditioning_stop` →
//    `auto_conditioning_start` is the one client-side sequence that WOULD land the
//    car in auto, and it is not ours to perform: it turns the owner's climate off
//    for a beat, mid-ride, with a rider in the car, to satisfy a segmented
//    control. That is a product decision, not an implementation detail.
//  • **No verdict without evidence.** The deadline alone does not condemn the
//    command — a car that has streamed nothing since the ack has not disagreed
//    with anything. Only a frame that REPORTS a different mode after the deadline
//    is a `.notAdopted`.
//
// **The honest close is server-side and is reported rather than attempted here:**
// the command proxy in the telemetry repo is the only place that can read the
// car's `hvac_auto_mode` back after applying `auto_conditioning_start` and answer
// the client with whether the mode actually moved (or refuse the command outright
// when it cannot move it). Until it does, this client can only observe and say so.

/// What the car's reported mode means for an Auto command we are waiting on.
enum ClimateAutoVerdict: Equatable, Sendable {
    /// The car reports auto — the command landed. Adopt and say nothing.
    case confirmed
    /// The car disagrees but the confirmation window is still open. Hold the
    /// optimistic Auto; a stale `Override` frame a second after the ack is the
    /// MYR-274 flicker this window has always existed to absorb.
    case awaiting
    /// The window lapsed and the car is still reporting another mode. The command
    /// was applied and the car did not adopt it — adopt the car's mode AND tell
    /// the owner, because a segment that moves on its own explains nothing.
    case notAdopted
}

enum ClimateAutoConfirmation {

    /// One Auto command's outstanding confirmation.
    struct Pending: Equatable, Sendable {
        /// When a car still reporting a non-auto mode stops being "settling" and
        /// starts being "it did not take".
        let deadline: Date
    }

    /// The verdict for a reported mode against an outstanding confirmation.
    ///
    /// `reported` is the mode `LiveVehicleCommandExecutor.climateMode(autoMode:
    /// acEnabled:)` folded out of the frame — never `nil`, because an
    /// `Unknown`/absent HVAC mode asserts nothing and its caller returns before
    /// reaching here (a car that has said nothing has not disagreed).
    static func verdict(reported: VehicleClimateMode, pending: Pending, now: Date = Date()) -> ClimateAutoVerdict {
        if reported == .auto { return .confirmed }
        return now < pending.deadline ? .awaiting : .notAdopted
    }
}
