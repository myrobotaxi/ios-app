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

/// A state the app can be IN, which a step can wait for.
///
/// **This is how an interactive step ends, and the reason it is a state rather
/// than a tap is a bug this file shipped once.** The first cut had a `.tapTarget`
/// case advanced by a `handleTargetTapped()` the walkthrough was supposed to call
/// when the tester hit the real control — and nothing ever called it, because
/// nothing could: the coach-mark layer deliberately does not modify the screens it
/// tours, so it never sees their taps. Four of the twelve steps rendered no Next
/// button and could never advance. A brand-new rider was stranded on step one.
///
/// Observing the STATE the control mutates fixes it and is strictly better
/// evidence: the step advances because the app really did open search / really did
/// take the request, not because a gesture recognizer fired. It also collapses the
/// old `.tapTarget` / `.rideStatus` distinction, which was never real — "the
/// tester tapped Accept" and "the car arrived" are both just the app reaching a
/// state, and only the walkthrough cared which agent caused it.
public enum DemoMilestone: String, Sendable, Hashable, CaseIterable {
    /// The rider opened the search sheet.
    case searchOpened
    /// The rider chose a destination and is looking at the review sheet.
    case destinationChosen
    /// The rider asked for the car.
    case requestSubmitted
    /// The owner sent the car.
    case rideAccepted
    /// The car reached the pickup.
    case rideArrived
    /// The ride ended.
    case rideCompleted
}

/// What ends a step.
public enum DemoAdvance: Equatable, Sendable {
    /// Nothing to do but read: the caption carries a Next (or, on the last step,
    /// the role's closing CTA).
    case next
    /// The app reaches this state. The overlay renders NO advance button for
    /// these — the real control (or the ride itself) is the only way on, which is
    /// what makes this a demo rather than a slideshow.
    case appReaches(DemoMilestone)
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
            // Names the button's REAL label. The first draft said "tap Send the
            // car" and the control reads "Accept & send" — a coach mark naming a
            // control that does not exist is worse than no coach mark, and only
            // reading the button's own definition caught it.
            body: "Tap Accept & send and your Tesla is on its way. Go ahead — this is a practice request, so nothing real is sent.",
            anchor: .ownerAcceptButton,
            advance: .appReaches(.rideAccepted)
        ),
        FirstRunDemoStep(
            id: "ownerDispatch",
            title: "Watch it go.",
            body: "The car drives itself to the pickup and the card up here tracks it. When it gets there, tap Arrived at pickup.",
            anchor: .ownerDispatchCard,
            advance: .appReaches(.rideArrived)
        ),
        FirstRunDemoStep(
            id: "ownerDroppedOff",
            title: "End the ride.",
            body: "Your rider is aboard. When they get out, tap Dropped off — that closes the ride and frees the car for the next one.",
            anchor: .ownerDispatchAction,
            advance: .appReaches(.rideCompleted)
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
            advance: .appReaches(.searchOpened)
        ),
        FirstRunDemoStep(
            id: "riderDestination",
            title: "Pick a destination.",
            // **NAMES BOTH TAPS, BECAUSE THE FLOW HAS TWO.** The first draft read
            // "Tap a destination to carry on" and it was wrong in the same way
            // "tap Send the car" was wrong last round — and it took TWO rounds of
            // driving the real flow to find out how wrong, because the step ends on
            // the REVIEW sheet and there are two controls between a destination row
            // and that sheet:
            //
            //  1. choosing a row FILLS the field and reveals a gold "Continue"
            //     (MYR-215/MYR-356 — `selectDestination` is the funnel that
            //     advances, and a row tap is not it), and
            //  2. Continue does not go to Review either: it goes to the PIN-DROP
            //     pickup confirmation ("Confirm pickup here"), which is the
            //     shipping path `pinDropRealPath` exists to capture.
            //
            // So a tester following the first draft tapped a destination and
            // stopped, on a step that had told them they were done. Reading the
            // script could not show this; only walking it could.
            // **AND IT NO LONGER SAYS "TYPE AN ADDRESS", BECAUSE THE FIELD IS NOT
            // VISIBLE ON THIS STEP.** The search sheet puts its destination field at
            // its own top edge, which is precisely the band a top-placed caption
            // takes — so the card covers it (the capture shows a sliver of the gold
            // field peeking out beside the card). The keyboard is up and focused, so
            // a tester who followed that instruction would be typing into something
            // they cannot see. This is the honest cost of placing captions in a BAND
            // rather than around a measured frame (see `DemoCoachMark`'s header: an
            // anchored ring would mean the toured screens publishing their geometry),
            // and the answer is to name only what is on screen: the rows the step's
            // own anchor points at.
            body: "Choose one of these, then tap Continue and confirm your pickup.",
            anchor: .riderDestinationList,
            advance: .appReaches(.destinationChosen)
        ),
        FirstRunDemoStep(
            id: "riderRequest",
            title: "Ask for the car.",
            body: "Check the trip, then request it. The owner gets your request instantly and can send the car your way.",
            anchor: .riderRequestButton,
            advance: .appReaches(.requestSubmitted)
        ),
        // Waits on ACCEPTED, not completed. The rest of a ride's states belong to
        // the owner (`pickedUp`) and this rider's own later tap (`startRide`), and
        // the rider walkthrough has no owner in the room — see
        // `FirstRunDemoHost.prepareStep`, which plays the absent owner's parts as
        // a cue on the NEXT step rather than stranding this one waiting for a
        // transition nobody present can make.
        FirstRunDemoStep(
            id: "riderTrack",
            title: "Track every minute.",
            body: "The owner takes the request and the car sets off. Follow it on the map with a live ETA, right up to the second it arrives.",
            anchor: .riderTrackingSheet,
            advance: .appReaches(.rideAccepted)
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
