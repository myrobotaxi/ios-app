import Foundation

// MARK: - MYR-428 — what each walkthrough says, and what ends each step
//
// THE DEMO ABSORBS THE STORY DECKS; it does not precede them or sit beside them.
//
// `OwnerTutorial` / `RiderTutorial` (MYR-166, design/app/tutorials.jsx:355-375)
// are five ILLUSTRATED CARDS each — a mini-map vignette, a fake drives list, a
// fake roster, a fake request card, a 2×2 control grid — shown once at an
// onboarding hand-off. The client's ask names the same teaching job and rules the
// format out in the same sentence: an *interactive* demo, over the app, not a
// deck. **Client outranks prototype** is this repo's standing precedent (MYR-346
// deleted the prototype's whole FSD celebration; MYR-347 replaced its Share tab
// grammar), and it applies here for the additional reason that the deck's
// vignettes are DRAWINGS OF SCREENS THE WALKTHROUGH NOW SHOWS FOR REAL. Keeping
// both would teach the same five things twice, the second time with worse
// fidelity — and on the invite path (MYR-426: join → RiderTutorial → the live
// map) it would be two teaching surfaces back to back, which is exactly the
// composition failure this issue was told to avoid.
//
// So the deck's coverage is preserved rather than dropped, and this file is where
// that is auditable: every card in each deck maps onto a step below, either
// because the walkthrough drives that surface for real (cards 1 and 4 owner /
// 1 and 2 rider) or because a step points at where it lives (cards 2, 3, 5
// owner / 3, 4, 5 rider). `FirstRunDemoScriptTests` asserts the mapping is total,
// so retiring a deck cannot quietly retire what it taught.
//
// TWO STEP-DESIGN RULES:
//
//  • **A step that names a control ADVANCES ON THAT CONTROL.** The demo is
//    interactive because the tester's own tap on the real, live "Send the car"
//    button is what moves the walkthrough on — not a Next button beside a picture
//    of one. `.tapTarget` steps have no Next affordance at all, because offering
//    both would make the real control optional and it is the entire lesson.
//  • **A step that names a PROCESS advances on the process.** Watching a dispatch
//    run is not a tap, so those steps end when the simulated service reaches the
//    status the copy just promised (`.status`) — the walkthrough and the ride
//    stay in lockstep by construction rather than by a timer that can drift out
//    of step with a service whose own timings are `RideRequestTiming`'s to change.

/// What the coach mark points at. A NAMED anchor rather than a frame, because the
/// walkthrough must not know any screen's geometry — the toured screens publish
/// these through `DemoAnchorKey` and the overlay reads them back. A step whose
/// anchor is absent on the frame renders its caption unanchored rather than
/// pointing at nothing (see `DemoCoachMarkOverlay`).
public enum DemoAnchor: String, Sendable, Hashable, CaseIterable {
    // Owner
    case ownerVehicleHero
    case ownerIncomingCard
    case ownerAcceptButton
    case ownerDispatchCard
    case ownerDispatchAction
    case ownerTabBar
    // Rider
    case riderSearchBar
    case riderDestinationList
    case riderRequestButton
    case riderTrackingSheet
    case riderSummaryCard
    case riderTabBar
}

/// What ends a step.
public enum DemoAdvance: Equatable, Sendable {
    /// The tester taps the real control the step is pointing at. The overlay
    /// renders NO Next button for these — the control is the only way on.
    case tapTarget
    /// Nothing to tap: the caption carries a Next (or, on the last step, the
    /// role's closing CTA).
    case next
    /// The simulated ride reaches this status. Used for the two steps that are
    /// about a process rather than a control.
    case rideStatus(DemoRideStatus)
}

/// The ride statuses a step can wait on, mirrored as its own type so this script
/// layer does not depend on the service module (and so a test can drive it with
/// no service at all). `FirstRunDemoHost` maps `RideRequestStatus` onto it.
public enum DemoRideStatus: String, Sendable, Hashable {
    case accepted
    case arrived
    case enroute
    case completed
}

/// One coach-marked step.
public struct FirstRunDemoStep: Identifiable, Equatable, Sendable {
    /// Stable across copy edits — it names the STEP, not its sentence. Used by
    /// the UI tests, by the capture filenames in the PR, and as the accessibility
    /// identifier suffix, so a renamed headline does not invalidate any of them.
    public let id: String
    public let title: String
    public let body: String
    public let anchor: DemoAnchor
    public let advance: DemoAdvance
    /// The label on the affordance that ends a `.next` step. Ignored for the
    /// other two kinds, which have no button of their own.
    public let nextLabel: String

    public init(
        id: String,
        title: String,
        body: String,
        anchor: DemoAnchor,
        advance: DemoAdvance,
        nextLabel: String = "Next"
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.anchor = anchor
        self.advance = advance
        self.nextLabel = nextLabel
    }

    /// `mrt.demo.step.<id>` — the `mrt.<surface>.<element>` grammar the ride flow
    /// already uses (`mrt.search.changeTrip`, `mrt.search.clearDestination`).
    public var accessibilityID: String { "mrt.demo.step.\(id)" }
}

/// The two walkthroughs.
public enum FirstRunDemoScript {
    public static func steps(for role: FirstRunDemoRole) -> [FirstRunDemoStep] {
        switch role {
        case .owner: return owner
        case .rider: return rider
        }
    }

    /// The kicker above the caption — the deck's own, kept, because it is the one
    /// piece of the story-deck chrome that still describes what is happening.
    public static func kicker(for role: FirstRunDemoRole) -> String {
        switch role {
        case .owner: return "Getting started"
        case .rider: return "Welcome aboard"
        }
    }

    /// The label that ends the walkthrough — likewise the deck's own
    /// (tutorials.jsx:363, :374), so the last tap reads exactly as it did.
    public static func finishLabel(for role: FirstRunDemoRole) -> String {
        switch role {
        case .owner: return "Go to my car"
        case .rider: return "Start riding"
        }
    }

    // MARK: Owner — incoming request → accept → dispatch → dropped off

    static let owner: [FirstRunDemoStep] = [
        FirstRunDemoStep(
            id: "ownerLiveMap",
            title: "Your car, live.",
            body: "Location, speed, battery and status — always a glance away. Drag the sheet up for the full picture.",
            anchor: .ownerVehicleHero,
            advance: .next
        ),
        FirstRunDemoStep(
            id: "ownerIncoming",
            title: "Someone wants a ride.",
            body: "A request arrives with the destination, the distance and who is asking, so you can decide at a glance.",
            anchor: .ownerIncomingCard,
            advance: .next
        ),
        FirstRunDemoStep(
            id: "ownerAccept",
            title: "Send the car.",
            body: "One tap dispatches your Tesla. Go ahead — this is a practice request, so nothing real is sent.",
            anchor: .ownerAcceptButton,
            advance: .tapTarget
        ),
        FirstRunDemoStep(
            id: "ownerDispatch",
            title: "Watch it go.",
            body: "The car drives itself to the pickup. You will see it move, and the status line tells you where it is.",
            anchor: .ownerDispatchCard,
            advance: .rideStatus(.arrived)
        ),
        FirstRunDemoStep(
            id: "ownerDroppedOff",
            title: "End the ride.",
            body: "When your rider is out, tap Dropped off. That closes the ride and frees the car for the next one.",
            anchor: .ownerDispatchAction,
            advance: .tapTarget
        ),
        FirstRunDemoStep(
            id: "ownerTabs",
            title: "Drives, sharing and controls.",
            body: "Every trip logs itself under Drives. Share lets people you trust watch or ride. Comfort and locks live in the sheet above.",
            anchor: .ownerTabBar,
            advance: .next,
            nextLabel: "Go to my car"
        ),
    ]

    // MARK: Rider — search → book → track → complete

    static let rider: [FirstRunDemoStep] = [
        FirstRunDemoStep(
            id: "riderWhereTo",
            title: "Where to?",
            body: "Tap the search bar to start a ride. This is a practice run on a sample car — no real request is made.",
            anchor: .riderSearchBar,
            advance: .tapTarget
        ),
        FirstRunDemoStep(
            id: "riderDestination",
            title: "Pick a destination.",
            body: "Type an address or choose one of these. Tap a destination to carry on.",
            anchor: .riderDestinationList,
            advance: .tapTarget
        ),
        FirstRunDemoStep(
            id: "riderRequest",
            title: "Ask for the car.",
            body: "Check the trip, then request it. The owner gets your request instantly and can send the car your way.",
            anchor: .riderRequestButton,
            advance: .tapTarget
        ),
        FirstRunDemoStep(
            id: "riderTrack",
            title: "Track every minute.",
            body: "Follow the Tesla on the map with a live ETA, from the moment it sets off to the second it arrives.",
            anchor: .riderTrackingSheet,
            advance: .rideStatus(.completed)
        ),
        FirstRunDemoStep(
            id: "riderComplete",
            title: "You're there.",
            body: "Every ride ends with a summary — the route you took, how long it took, and how far you went.",
            anchor: .riderSummaryCard,
            advance: .next
        ),
        FirstRunDemoStep(
            id: "riderBoundaries",
            title: "What you can do.",
            body: "Request rides, watch the live map, and revisit past trips. You can never unlock or drive the car — the owner always stays in charge.",
            anchor: .riderTabBar,
            advance: .next,
            nextLabel: "Start riding"
        ),
    ]

    // MARK: - The deck-coverage audit
    //
    // Which retired story card each step carries. Asserted total by
    // `FirstRunDemoScriptTests` so the absorption stays a fact rather than a
    // claim in a comment: retiring a deck must not quietly retire what it taught.

    /// The five owner cards (tutorials.jsx:355-364), by their titles, mapped to
    /// the step id that now covers each.
    public static let ownerDeckCoverage: [String: String] = [
        "Your car, live.": "ownerLiveMap",
        "Send the car to anyone.": "ownerAccept",
        "Every drive, remembered.": "ownerTabs",
        "Share with people you trust.": "ownerTabs",
        "Comfort, before you’re in.": "ownerTabs",
    ]

    /// The five rider cards (tutorials.jsx:366-375).
    public static let riderDeckCoverage: [String: String] = [
        "Request a ride in seconds.": "riderWhereTo",
        "Track every minute.": "riderTrack",
        "Your rides, saved.": "riderComplete",
        "Cars shared with you.": "riderBoundaries",
        "Clear boundaries.": "riderBoundaries",
    ]
}
