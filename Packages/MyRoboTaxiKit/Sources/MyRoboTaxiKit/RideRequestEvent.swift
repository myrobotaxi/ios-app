import MyRobotaxiContracts

/// One event on the ride-request stream the ``TelemetrySocket`` demultiplexes
/// out of its single authenticated connection (websocket-protocol.md §4.7/§4.8,
/// P10 ride-hailing — MYR-174). Unlike ``VehicleTelemetryEvent`` these frames are
/// NOT keyed by vehicle: the server unicasts them to the two parties of a ride
/// (the requesting rider + the vehicle owner), so the socket surfaces them on one
/// account-wide stream rather than a per-vehicle one.
///
/// Both payloads are deliberately SUMMARY-ONLY (like `drive_ended`, DV-11): they
/// carry the ids + status + `scheduledFor` needed to badge the right card, but
/// NOT the pickup/dropoff places or the booked-for passenger (those are P1 and
/// kept off the broadcast path). A consumer that needs the full record refetches
/// `RestClient.rideRequest(id:)` on the frame.
///
/// Contracts v0.11.0 (MYR-229) adds one exception: both payloads also carry an
/// OPTIONAL `requesterName` (server "first name -> email local-part -> Rider"
/// fallback) so the owner's incoming card can badge the real requester without
/// waiting on the refetch. The app currently still relies on the refetched
/// `RideRequest.requesterName` (`RideRequestContractMapping.record(from:)`) for
/// display, since every frame already triggers one; a consumer that wants to
/// paint the name before the refetch lands can read it straight off these
/// payloads with no Kit changes — they are the generated contracts types
/// unchanged, so the field is already here.
public enum RideRequestEvent: Sendable {
    /// `ride_request_created` — a NEW ride request (always `status == requested`
    /// today). Delivered to the owner (drives the IncomingRequestSheet) and
    /// echoed to the rider so multiple devices converge.
    case created(RideRequestCreatedPayload)
    /// `ride_status_changed` — a MUTATION of an existing request: an owner
    /// accept/decline, a rider cancel, or (future MYR-176/177) dispatch progress.
    /// Consumers key on `(status, rescheduleStatus)` and refetch for the rest.
    case statusChanged(RideStatusChangedPayload)
}
