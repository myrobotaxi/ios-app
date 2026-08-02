import Foundation

// MARK: - What a push means to a running app (MYR-186)
//
// Two decisions, both PURE so the whole matrix is unit-testable with no
// notification centre, no simulator and no screens:
//
//   1. FOREGROUND PRESENTATION — the app is already open. Showing a banner for
//      something the user is already looking at is noise, and worse: on the owner
//      side the banner covers the incoming card's own Accept/Decline buttons. So
//      a notification is SUPPRESSED when its target surface is already frontmost
//      for that exact ride, and presented otherwise.
//
//   2. TAP ROUTING — the app must arrive at an EXISTING surface via EXISTING
//      state. There is no new navigation machinery here and there must not be:
//      the owner's incoming card already surfaces from the ride-request service's
//      queue/refresh machinery, and the rider's flow already adopts by refetch.
//      A tap therefore resolves to "which shell + which refresh to poke", not to
//      a route stack.

/// The payload fields the app actually reads off a notification: the ride it is
/// about. `aps` alert title/body are rendered by the system, never by us.
struct PushRideNotification: Equatable {
    /// `userInfo["rideId"]`.
    var rideID: String

    /// Extract the ride id from a `userInfo` dictionary, or `nil` when the
    /// payload carries none (a notification the app has no opinion about —
    /// it presents normally and its tap routes nowhere in particular).
    static func from(userInfo: [AnyHashable: Any]) -> PushRideNotification? {
        guard let rideID = userInfo["rideId"] as? String, !rideID.isEmpty else { return nil }
        return PushRideNotification(rideID: rideID)
    }
}

/// What the app is currently showing, reduced to only what the two decisions
/// need. Assembled from state that ALREADY exists (`role`, the owner tab, the
/// ride-request service's `activeRequest`, the rider sheet phase) — this type
/// holds no state of its own and is never a source of truth.
struct PushSurfaceContext: Equatable {
    var role: UserRole
    /// The owner's incoming-request card is on screen (owner shell, home tab,
    /// a pending `activeRequest`) — and this is the ride it is showing.
    var ownerIncomingRideID: String?
    /// The rider's tracking sheet is on screen — and this is the ride it tracks.
    var riderTrackingRideID: String?

    init(role: UserRole, ownerIncomingRideID: String? = nil, riderTrackingRideID: String? = nil) {
        self.role = role
        self.ownerIncomingRideID = ownerIncomingRideID
        self.riderTrackingRideID = riderTrackingRideID
    }
}

/// Whether to show the banner while the app is in the foreground.
enum PushForegroundPresentation: Equatable {
    /// Show the system banner (+ sound/badge) over the app.
    case present
    /// Stay silent — the user is already looking at this ride's surface.
    case suppress
}

/// MYR-424 — whether a notification RECEIVED while the app is in the foreground
/// should also poke the ride-refresh funnel.
///
/// Separate from ``PushForegroundPresentation`` on purpose: "should the user SEE
/// a banner" and "should the app RE-READ the ride" are different questions with
/// different right answers, and the r20 defect is exactly what happens when the
/// second one is never asked.
enum PushForegroundRefresh: Equatable {
    /// Re-read the ride this notification names, through the existing funnel.
    case refresh
    /// Nothing to converge on — the notification names no ride.
    case skip
}

/// Where a notification TAP should land the user. Both cases name an EXISTING
/// shell and the EXISTING refresh that repopulates it; neither pushes a screen.
enum PushTapRoute: Equatable {
    /// Owner shell, home tab. The incoming card then surfaces through the
    /// ride-request service's own queue/refresh machinery (`refreshIncoming`) —
    /// the same path a live `ride_request_created` frame takes.
    case ownerHome
    /// Rider shell, live-map tab. The rider's services adopt the current ride by
    /// refetch, exactly as they do on a cold launch mid-ride.
    case riderActiveFlow
}

enum PushNotificationRouting {

    /// Decide whether a foreground notification shows a banner.
    ///
    /// Suppression is deliberately RIDE-SPECIFIC, not surface-specific: an owner
    /// staring at request A must still be told about request B, because B is
    /// exactly the thing they cannot see. Suppressing on "the incoming card is
    /// up" alone would hide the second rider entirely.
    ///
    /// A notification with no ride id is always presented — the app has no basis
    /// to claim the user is already looking at it.
    static func foregroundPresentation(
        notification: PushRideNotification?,
        context: PushSurfaceContext
    ) -> PushForegroundPresentation {
        guard let notification else { return .present }

        switch context.role {
        case .owner:
            // The owner's incoming card for THIS ride is frontmost — the banner
            // would cover its own Accept/Decline buttons.
            return context.ownerIncomingRideID == notification.rideID ? .suppress : .present
        case .shared:
            // The rider is watching THIS ride's tracking sheet; every state the
            // notification announces is already on screen and updating.
            return context.riderTrackingRideID == notification.rideID ? .suppress : .present
        }
    }

    /// MYR-424 — decide whether a notification the app RECEIVED while foreground
    /// should re-read the ride it names.
    ///
    /// **This deliberately takes no `PushSurfaceContext`, and that is the fix.**
    /// The r20 report is a rider foregrounded on the Live Map with the decline
    /// banner "Lunar can't take this ride" ON SCREEN and the pill below still
    /// reading "Request sent · Waiting for Lunar": the push proved the server had
    /// recorded the decline (`go_ride_requests.updated_at` 16:18:19Z, status
    /// `declined`) and the app did nothing with that proof, because
    /// `willPresent` only ever decided whether to draw a banner. A push is a
    /// SIGNAL, not just a banner — and the one thing it is always evidence of is
    /// that the server knows something about this ride that this client may not.
    ///
    /// Taking no context also makes the independence STRUCTURAL rather than
    /// merely tested: a suppressed banner (the rider is already on this ride's
    /// tracking sheet) is the case that needs the re-read MOST, because the
    /// surface being suppressed in favour of is the stale one. There is no way
    /// to write a suppression rule here that could accidentally gate the refresh.
    ///
    /// The refresh at the far end resolves the ride by refetch, so this only has
    /// to answer "is there a ride to ask about at all".
    static func foregroundRefresh(notification: PushRideNotification?) -> PushForegroundRefresh {
        notification == nil ? .skip : .refresh
    }

    /// Decide where a notification TAP lands. Purely a function of role: each
    /// role has exactly one surface where a ride is dealt with, and the ride id
    /// is what the refresh at the far end resolves — the route itself does not
    /// vary per ride.
    static func tapRoute(
        notification: PushRideNotification?,
        role: UserRole
    ) -> PushTapRoute {
        switch role {
        case .owner: return .ownerHome
        case .shared: return .riderActiveFlow
        }
    }
}
