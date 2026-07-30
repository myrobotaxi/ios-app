import Foundation
import MyRobotaxiContracts

/// The snapshot half of the read-path, factored into its own protocol so the
/// telemetry socket depends only on "give me the current `VehicleState`" and can
/// be tested with a stub. `RestClient` is the production conformer.
public protocol SnapshotFetching: Sendable {
    /// `GET /api/vehicles/{vehicleId}/snapshot` — the reconnect baseline
    /// (NFR-3.11, Rule CG-SM-4).
    func snapshot(vehicleId: String) async throws -> VehicleState
}

/// URLSession-based REST client for the read-path the app needs first. Base-URL
/// + bearer-token injection via an async ``TokenProvider`` (MYR-193's real auth
/// slots in). Every response decodes into a generated `MyRobotaxiContracts`
/// type — the client owns no wire shapes of its own.
///
/// Value type (`Sendable`): all dependencies are immutable, so it is free to
/// share across tasks without a serialization bottleneck.
public struct RestClient: Sendable, SnapshotFetching, AuthenticationEndpoint, TeslaLinkEndpoint, VehicleTeardownEndpoint, VehiclePlateEndpoint, VehicleServiceWindowEndpoint, VehicleRideShareEndpoint, VehicleRefreshing, VehicleCommandSending, VehicleSharingEndpoint, PushDeviceEndpoint {
    private let environment: BackendEnvironment
    private let tokenProvider: any TokenProvider
    private let http: any HTTPPerforming
    private let decoder: JSONDecoder

    public init(
        environment: BackendEnvironment,
        tokenProvider: any TokenProvider,
        http: any HTTPPerforming
    ) {
        self.environment = environment
        self.tokenProvider = tokenProvider
        self.http = http
        self.decoder = JSONDecoder()
    }

    /// Convenience initializer wiring a `URLSession` tuned per swift-lifecycle.md
    /// §4 (waits-for-connectivity, request/resource timeouts).
    public init(environment: BackendEnvironment, tokenProvider: any TokenProvider) {
        self.init(
            environment: environment,
            tokenProvider: tokenProvider,
            http: URLSession(configuration: RestClient.defaultConfiguration())
        )
    }

    // MARK: - Endpoints

    /// `GET /api/vehicles` — the caller's vehicle catalog (rest-api.md §7.0).
    /// Returns the unwrapped rows; the `VehicleListResponse` envelope is a
    /// contract detail handled here.
    public func vehicles() async throws -> [VehicleSummary] {
        let response: VehicleListResponse = try await get(["vehicles"])
        return response.items
    }

    /// `GET /api/vehicles/{vehicleId}/snapshot` — cold-load full `VehicleState`
    /// (rest-api.md §7.1). This is the snapshot the telemetry socket re-fetches
    /// before resuming the live stream on every reconnect (NFR-3.11, CG-SM-4).
    public func snapshot(vehicleId: String) async throws -> VehicleState {
        try await get(["vehicles", vehicleId, "snapshot"])
    }

    /// `GET /api/vehicles/{vehicleId}/drives` — one page of the vehicle's
    /// completed-drive history, newest first (rest-api.md §7.2). Cursor-based
    /// pagination (§4.2): pass a prior response's `nextCursor` to fetch the next
    /// page; `nil` on the first page. Use `hasMore` (or `nextCursor != nil`) as
    /// the paging predicate — `null nextCursor` means the last page. `limit` is
    /// clamped to the contract's 1…100 range. Returns the `DrivesListResponse`
    /// envelope (items + nextCursor + hasMore) — the envelope IS the contract,
    /// so it is surfaced whole rather than unwrapped.
    public func drives(
        vehicleID: String,
        cursor: String? = nil,
        limit: Int = 20
    ) async throws -> DrivesListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(["vehicles", vehicleID, "drives"], query: query)
    }

    /// `GET /api/drives/{driveId}` — the full FR-3.4 record for one completed
    /// drive (rest-api.md §7.3): the detail-only `energyUsedKwh` / `interventions`
    /// on top of the `DriveSummary` stats. The tap-through target behind a
    /// `DriveSummary` row / a `drive_ended` frame (the SDK's `fetchDrive`).
    /// Returned as a bare object (no envelope).
    public func drive(id: String) async throws -> Drive {
        try await get(["drives", id])
    }

    /// `GET /api/drives/{driveId}/route` — the full GPS polyline for one
    /// completed drive (rest-api.md §7.4, `DriveRoute`). Deliberately excluded
    /// from both the drives list (§7.2) and drive detail (§7.3): it is the heavy
    /// per-drive payload (~3.6k points / ~250 KB for an hour drive), fetched
    /// LAZILY on tap-through of a drive's map, never eagerly per list row (§7.4
    /// lazy-fetch guidance — cellular bandwidth / perceived latency). Returned as
    /// a bare object; `routePoints` is ALWAYS an array (`[]`, never null, for a
    /// very short drive) — callers branch on `.isEmpty`, not on optionality.
    public func driveRoute(id: String) async throws -> DriveRoute {
        try await get(["drives", id, "route"])
    }

    // MARK: - Ride requests (rest-api.md §7.8, P10 ride-hailing — MYR-174 rider
    // surface + MYR-175 owner surface)
    //
    // Every method decodes a generated `MyRobotaxiContracts` ride type — the Kit
    // owns no ride shapes of its own. The single-resource paths return a bare
    // `RideRequest`; the list paths return the `RideRequestsListResponse`
    // envelope whole (the envelope IS the contract, same as `drives`). An illegal
    // lifecycle mutation surfaces as `RestError.http(status: 409, code: .conflict …)`
    // (§7.8 transition matrix) — callers MUST NOT auto-retry the same mutation.

    /// `POST /api/ride-requests` (rest-api.md §7.8) — the rider's Review-sheet
    /// submit. Body is the strict `RideRequestCreateRequest` (unknown keys →
    /// `400 invalid_request` server-side). Responds `201 Created` with the full
    /// server-assigned `RideRequest` and unicasts `ride_request_created` to the
    /// rider + owner over the WS.
    public func createRideRequest(_ body: RideRequestCreateRequest) async throws -> RideRequest {
        try await post(["ride-requests"], body: body)
    }

    /// `GET /api/ride-requests` (rest-api.md §7.8) — the authenticated rider's
    /// own requests, newest first (`createdAt DESC, id DESC`), cursor-paginated
    /// per §4.2. Returns the envelope whole (`items` always present — `[]` never
    /// null; `nextCursor` null on the final page).
    public func rideRequests(cursor: String? = nil, limit: Int = 20) async throws -> RideRequestsListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(["ride-requests"], query: query)
    }

    /// `GET /api/ride-requests/incoming` (rest-api.md §7.8, MYR-175) — the
    /// OWNER's feed of open (`requested`-only) requests across their vehicles,
    /// on-demand + scheduled variants both. Same envelope + `(createdAt, id)`
    /// cursor as `rideRequests`. Decided rows leave the feed by construction.
    public func incomingRideRequests(cursor: String? = nil, limit: Int = 20) async throws -> RideRequestsListResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(["ride-requests", "incoming"], query: query)
    }

    /// The query parameter that turns the owner's incoming feed into the
    /// UPCOMING-RESERVATIONS view of ONE vehicle (MYR-360).
    ///
    /// Named as a constant rather than spelled inline because it is the ONE piece
    /// of this feature the client and the server have to agree on by string: if the
    /// backend lands a different name, this is a one-line change with a test on it,
    /// not a search across the app.
    public static let upcomingForVehicleQueryName = "upcomingForVehicle"

    /// `GET /api/ride-requests/incoming?upcomingForVehicle={id}` (MYR-360) — the
    /// owner's ACCEPTED reservations for ONE vehicle whose `scheduled_for` is
    /// strictly in the FUTURE, ordered SOONEST FIRST.
    ///
    /// The same endpoint, envelope, cursor and limit clamp as
    /// ``incomingRideRequests(cursor:limit:)`` — the parameter selects a different
    /// SLICE of the owner's ride requests, not a different resource. Two properties
    /// the caller depends on: items carry `requesterName` (server-resolved FIRST
    /// name) and `scheduledFor`, and an unknown or unowned `vehicleID` answers an
    /// EMPTY PAGE rather than an error, so a stale vehicle id degrades to "no
    /// reservations" instead of to a failure the owner has to interpret.
    public func upcomingReservations(
        vehicleID: String,
        cursor: String? = nil,
        limit: Int = 20
    ) async throws -> RideRequestsListResponse {
        var query: [URLQueryItem] = [
            URLQueryItem(name: Self.upcomingForVehicleQueryName, value: vehicleID),
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))
        ]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(["ride-requests", "incoming"], query: query)
    }

    /// `GET /api/ride-requests/{id}` (rest-api.md §7.8) — the full `RideRequest`
    /// behind a `ride_request_created` / `ride_status_changed` summary frame
    /// (the frames are summary-only; pickup/dropoff/passenger live here). Party-
    /// only server-side: a non-party gets `404` (existence is never leaked).
    public func rideRequest(id: String) async throws -> RideRequest {
        try await get(["ride-requests", id])
    }

    /// `POST /api/ride-requests/{id}/cancel` (rest-api.md §7.8) — RIDER-only.
    /// Legal from `requested`/`accepted` → `cancelled`; any other state is
    /// `409 conflict`. Responds `200 OK` with the updated `RideRequest`.
    public func cancelRideRequest(id: String) async throws -> RideRequest {
        try await post(["ride-requests", id, "cancel"], body: Optional<Empty>.none)
    }

    /// `POST /api/ride-requests/{id}/accept` (rest-api.md §7.8, MYR-175) —
    /// OWNER-only. Legal only from `requested` → `accepted`; else `409 conflict`.
    /// Responds `200 OK` with the updated `RideRequest` (now carrying
    /// `acceptedAt`) and unicasts `ride_status_changed` to both parties.
    public func acceptRideRequest(id: String) async throws -> RideRequest {
        try await post(["ride-requests", id, "accept"], body: Optional<Empty>.none)
    }

    /// `POST /api/ride-requests/{id}/decline` (rest-api.md §7.8, MYR-175) —
    /// OWNER-only. Legal from `requested` → `declined`, and — MYR-360 — from
    /// `accepted` → `declined` for a SCHEDULED ride, so an owner pausing ride
    /// sharing can withdraw the reservations that pause would otherwise strand.
    /// An accepted INSTANT ride is still `409 conflict` (a car already on its way
    /// is not declinable), as is every other state.
    public func declineRideRequest(id: String) async throws -> RideRequest {
        try await post(["ride-requests", id, "decline"], body: Optional<Empty>.none)
    }

    /// `POST /api/ride-requests/{id}/picked-up` (rest-api.md §7.8, MYR-270 —
    /// owner-driven dispatch v2) — the OWNER confirms the rider is aboard: leg 1 →
    /// "picked up". OWNER-only (party auth). Guarded `accepted → arrived`. This does
    /// NOT push any nav (the DROPOFF nav is pushed by `start`, below, when the rider
    /// starts the ride). IDEMPOTENT — an already-`arrived` ride returns `200` with
    /// the current record (no-op), so a retry / re-tap is safe. Any OTHER status is
    /// `409 conflict`; the rider / a non-owner party gets `403`; a non-party `404`.
    /// Responds `200 OK` with the updated `RideRequest`. A `409` surfaces as a typed
    /// `RestError.http(status: 409, …)` the caller reconciles against server state
    /// (never an auto-retry of the same POST).
    public func pickedUp(rideID: String) async throws -> RideRequest {
        try await post(["ride-requests", rideID, "picked-up"], body: Optional<Empty>.none)
    }

    /// `POST /api/ride-requests/{id}/start` (rest-api.md §7.8, MYR-270) — the RIDER
    /// starts the ride once the owner has confirmed pickup: `arrived → enroute`. This
    /// is what PUSHES THE DROPOFF NAV to the car (server-side). RIDER-only (party
    /// auth). Guarded `arrived → enroute`, so a rider cannot start before the owner
    /// confirms pickup — a `start` from `accepted` is a `409 conflict`. IDEMPOTENT —
    /// an already-`enroute` ride returns `200` with the current record (no-op), so a
    /// retry / re-tap is safe. The owner / a non-rider party gets `403`; a non-party
    /// `404`. Responds `200 OK`. A `409` surfaces as a typed `RestError.http`.
    public func start(rideID: String) async throws -> RideRequest {
        try await post(["ride-requests", rideID, "start"], body: Optional<Empty>.none)
    }

    /// `POST /api/ride-requests/{id}/dropped-off` (rest-api.md §7.8, MYR-270) — the
    /// OWNER completes the ride at the drop-off: `enroute → completed`. OWNER-only
    /// (party auth). There is NO drive-end auto-completion anymore (MYR-270): the
    /// owner explicitly ends the ride here. IDEMPOTENT — an already-`completed` ride
    /// returns `200` with the current record (no-op), so a retry / re-tap is safe.
    /// Any OTHER status is `409 conflict`; the rider / a non-owner party gets `403`;
    /// a non-party `404`. Responds `200 OK`. A `409` surfaces as a typed
    /// `RestError.http` the caller reconciles against server state.
    public func droppedOff(rideID: String) async throws -> RideRequest {
        try await post(["ride-requests", rideID, "dropped-off"], body: Optional<Empty>.none)
    }

    /// Empty JSON body sentinel for the action POSTs that take no payload
    /// (`/cancel`, `/accept`, `/decline`). Encodes to `{}`.
    private struct Empty: Encodable {}

    // MARK: - Vehicle commands (rest-api.md §7.9, MYR-249 / P11 — owner actuation)

    /// `POST /api/vehicles/{vehicleId}/command/{name}` (§7.9) — send one owner
    /// Tesla command. The typed param body (`VehicleCommand.encodedBody()`) rides
    /// the standard authenticated pipeline (Bearer + single 401 refresh-retry).
    /// A non-2xx surfaces as a typed `RestError`; callers fold it via
    /// `RestError.commandFailureKind` (the §7.9 error catalog) — never string-match
    /// the human message. `perform` sends no `Content-Type`/body for the
    /// parameterless commands (empty body), exactly as §7.9 permits.
    public func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        let body = try command.encodedBody()
        return try await perform(
            ["vehicles", vehicleID, "command", command.name],
            method: "POST",
            body: body,
            allowTokenRefresh: true
        )
    }

    // MARK: - Authentication (rest-api.md §7.10, identity module — MYR-193)
    //
    // These three are PRE-AUTHENTICATION: they mint or rotate the very Bearer
    // credential every other endpoint requires. They therefore run the separate
    // `performAuth` pipeline below — NO `Authorization` header, and NO 401
    // refresh-retry (the retry loop is what calls `refreshSession`; routing
    // these through it would recurse). Bodies/responses are the local §7.10
    // shapes in `AuthPayloads.swift` (pending contracts codegen). `nonce` is
    // optional; when present it must equal the identity token's `nonce` claim.

    /// `POST /api/auth/apple` (§7.10.1) — validate a native Sign in with Apple
    /// identity token and mint the first token pair.
    public func signInWithApple(_ body: AppleSignInRequest) async throws -> AuthTokenResponse {
        try await performAuth(["auth", "apple"], body: body)
    }

    /// `POST /api/auth/refresh` (§7.10.2) — single-use refresh-token rotation.
    /// A spent/revoked token revokes the whole family → `401` (surfaced typed).
    public func refreshSession(_ body: RefreshTokenRequest) async throws -> AuthTokenResponse {
        try await performAuth(["auth", "refresh"], body: body)
    }

    /// `POST /api/auth/revoke` (§7.10.3) — revoke the token's family (sign-out).
    /// Always `204 No Content` for a well-formed request; the response body is
    /// discarded.
    public func revokeSession(_ body: RefreshTokenRequest) async throws {
        try await performAuthNoContent(["auth", "revoke"], body: body)
    }

    // MARK: - In-app Tesla account link (rest-api.md §7.11, MYR-246)

    /// `POST /api/tesla/link/start` (§7.11.1) — owner-authenticated; mints the
    /// Tesla authorize URL for the signed-in owner (server-side PKCE + `state`).
    /// No request body. Runs the standard authenticated `post` pipeline (Bearer +
    /// single 401 refresh-retry) — the caller must already hold a session. The
    /// returned `authorizeUrl` is opened in `ASWebAuthenticationSession` by the
    /// app; the code→token exchange completes server-side at the callback.
    public func teslaLinkStart() async throws -> TeslaLinkStartResponse {
        try await post(["tesla", "link", "start"], body: Optional<Empty>.none)
    }

    // MARK: - Owner car offboarding (rest-api.md §7.12, MYR-258)

    /// `DELETE /api/tesla/vehicles/{vehicleId}` (§7.12) — full owner teardown of
    /// one owned vehicle. Owner-authenticated (Bearer + single 401 refresh-retry
    /// via the shared `perform` pipeline); no request body. `{vehicleId}` is the
    /// Prisma cuid (NOT a VIN). Authoritative + idempotent — re-removing an
    /// already-gone car is a clean no-op (typically a `404`, mapped to a typed
    /// `RestError.http`). A `403 vehicle_not_owned` / `500 internal_error` surface
    /// as typed `RestError`s the caller folds into honest copy.
    public func removeVehicle(vehicleID: String) async throws -> VehicleTeardownResponse {
        try await perform(
            ["tesla", "vehicles", vehicleID],
            method: "DELETE",
            body: nil,
            allowTokenRefresh: true
        )
    }

    // MARK: - Owner license-plate entry (rest-api.md §7.14, MYR-286)

    /// `PUT /api/tesla/vehicles/{vehicleId}/plate` (§7.14) — store the owner's
    /// license plate for one owned vehicle. Owner-authenticated via the standard
    /// `perform` pipeline (Bearer + single 401 refresh-retry); `{vehicleId}` is
    /// the Prisma cuid (NOT a VIN), same key as §7.12.
    ///
    /// The body key is `plate` (see ``VehiclePlateUpdateRequest`` — the server
    /// strict-decodes and 400s on an unknown key); the response echoes the
    /// server-NORMALIZED value as `licensePlate`, which the caller adopts instead
    /// of the string it submitted. Idempotent, and an empty `plate` clears.
    /// No Tesla call is involved at any point — this is a local owner-scoped DB
    /// write, so the route is always mounted.
    public func setLicensePlate(_ plate: String, vehicleID: String) async throws -> VehiclePlateResponse {
        let body = try JSONEncoder().encode(VehiclePlateUpdateRequest(plate: plate))
        return try await perform(
            ["tesla", "vehicles", vehicleID, "plate"],
            method: "PUT",
            body: body,
            allowTokenRefresh: true
        )
    }

    // MARK: - Owner "expected back" service window (MYR-316)

    /// `PUT /api/tesla/vehicles/{vehicleId}/service-window` (MYR-316) — store the
    /// owner's expected-back time for one owned vehicle. Owner-authenticated via
    /// the standard `perform` pipeline (Bearer + single 401 refresh-retry);
    /// `{vehicleId}` is the Prisma cuid (NOT a VIN), same key as §7.12/§7.14.
    ///
    /// The body key is `expectedEndAt` (the owner's INPUT); the response echoes
    /// the server's RESOLVED `serviceEstimatedEndAt`, which the caller adopts
    /// instead of the string it submitted — Tesla's own `service_etc` outranks the
    /// owner's entry, so the two can legitimately differ (see
    /// ``VehicleServiceWindowUpdateRequest``). Idempotent, and `nil` clears (an
    /// empty string is accepted by the server as the same clear; this client sends
    /// an explicit `null`, the unambiguous form).
    ///
    /// `400 invalid_request` is the "not in the future" refusal, and it is the
    /// caller's job to have prevented it client-side — this endpoint mirrors the
    /// rule, it is not the owner's first line of feedback. No Tesla call is
    /// involved at any point, so the route is always mounted.
    public func setServiceWindow(expectedEndAt: String?, vehicleID: String) async throws -> VehicleServiceWindowResponse {
        let body = try JSONEncoder().encode(VehicleServiceWindowUpdateRequest(expectedEndAt: expectedEndAt))
        return try await perform(
            ["tesla", "vehicles", vehicleID, "service-window"],
            method: "PUT",
            body: body,
            allowTokenRefresh: true
        )
    }

    // MARK: - Owner ride-share pause toggle (rest-api.md §7.18, MYR-342)

    /// `PUT /api/tesla/vehicles/{vehicleId}/ride-share` (§7.18) — pause or resume
    /// ride requests for one owned vehicle. Owner-authenticated via the standard
    /// `perform` pipeline (Bearer + single 401 refresh-retry); `{vehicleId}` is the
    /// Prisma cuid (NOT a VIN), the same key as §7.12/§7.14/§7.16.
    ///
    /// The body key is `enabled` (the owner's INPUT) and so is the response key —
    /// NOT the read shapes' `rideShareEnabled`. The caller adopts the ECHO rather
    /// than the bool it submitted: this server writes exactly what was asked, so
    /// today they always agree, and the contract echoes anyway so a future server
    /// can refuse or coerce without breaking clients.
    ///
    /// `enabled` is REQUIRED — the one place §7.18 diverges from its §7.16
    /// template. There is no clear and no third state; absent/null/non-boolean are
    /// all `400 invalid_request`. No Tesla call is involved at any point, so the
    /// route is ALWAYS mounted — which is also the fail-safe direction: a gated
    /// route with the gate off would leave an owner unable to pause a car the
    /// rider-facing catalog still shows as available.
    public func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse {
        let body = try JSONEncoder().encode(VehicleRideShareUpdateRequest(enabled: enabled))
        return try await perform(
            ["tesla", "vehicles", vehicleID, "ride-share"],
            method: "PUT",
            body: body,
            allowTokenRefresh: true
        )
    }

    // MARK: - Owner on-demand refresh (rest-api.md §7.15, MYR-315)

    /// `POST /api/tesla/vehicles/{vehicleId}/refresh` (§7.15) — ask the server for
    /// a newer read of one owned vehicle. Owner-authenticated via the standard
    /// `perform` pipeline (Bearer + single 401 refresh-retry); `{vehicleId}` is the
    /// Prisma cuid (NOT a VIN), the same key as §7.12/§7.14. No request body.
    ///
    /// Two DISTINCT 200s (see ``VehicleRefreshResponse``): `fresh` (the car
    /// streamed recently — the server deliberately did nothing) and `refreshed`
    /// (it woke the car and read it). Both carry the authoritative `lastUpdated`,
    /// so a caller never infers freshness from "the call succeeded".
    ///
    /// The failures are typed, not stringly: `503 vehicle_asleep` folds to
    /// `.vehicleAsleep` and `429 rate_limited` to `.rateLimited` through the
    /// EXISTING `RestError.commandFailureKind` catalog — this endpoint reuses the
    /// §7.9 error vocabulary rather than inventing a second one.
    public func refreshVehicle(id: String) async throws -> VehicleRefreshResponse {
        try await perform(
            ["tesla", "vehicles", id, "refresh"],
            method: "POST",
            body: nil,
            allowTokenRefresh: true
        )
    }

    // MARK: - Vehicle sharing (rest-api.md §7.5, MYR-184)
    //
    // Every body and every response here is a generated contracts v0.19.0 type —
    // this family authors no local wire shapes at all (contrast §7.14/§7.16, whose
    // write bodies predate codegen coverage). All five run the standard
    // authenticated pipeline (Bearer + single 401 refresh-retry).

    /// `POST /api/vehicles/{vehicleId}/invites` (§7.5.1) — mint one code across the
    /// requested vehicle set. See ``VehicleSharingEndpoint/createShareInvite(_:vehicleID:)``.
    public func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite {
        try await post(["vehicles", vehicleID, "invites"], body: body)
    }

    /// `GET /api/vehicles/{vehicleId}/invites` (§7.5.2) — the owner's rows for one
    /// vehicle. The `invites` envelope is unwrapped here; it is deliberately NOT the
    /// `items`/`nextCursor`/`hasMore` shape of the paginated lists (this surface is
    /// unpaginated by contract), which is exactly why it must not be routed through
    /// any pagination helper.
    public func shareInvites(vehicleID: String) async throws -> [ShareInvite] {
        let response: ShareInviteListResponse = try await get(["vehicles", vehicleID, "invites"])
        return response.invites
    }

    /// `DELETE /api/invites/{inviteId}` (§7.5.3) — cancel a pending invite or revoke
    /// an accepted grant. `204 No Content`, so this runs `performDiscardingBody`:
    /// `perform` would fail a zero-byte 204 with `RestError.decoding`.
    public func revokeShareInvite(inviteID: String) async throws {
        try await performDiscardingBody(
            ["invites", inviteID],
            method: "DELETE",
            body: nil,
            allowTokenRefresh: true
        )
    }

    /// `POST /api/invites/{inviteId}/resend` (§7.5.4) — new code, fresh 7-day
    /// expiry, every sibling row re-minted atomically. The body is the PATH row.
    /// `409` (already accepted) surfaces typed via `RestError.isShareInviteAlreadyAccepted`.
    public func resendShareInvite(inviteID: String) async throws -> ShareInvite {
        try await post(["invites", inviteID, "resend"], body: Optional<Empty>.none)
    }

    /// `POST /api/invites/redeem` (§7.5.5) — the rider's join.
    ///
    /// The code is normalized CLIENT-SIDE (upper-case, strip everything outside
    /// `[A-Z0-9]`) before sending, exactly as the contract instructs and exactly as
    /// the entry field already does — the server normalizes identically, so this is
    /// belt-and-braces for a caller that did not come through the six-cell field.
    /// The code is a live bearer credential: it is never logged and never echoed.
    public func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse {
        let normalized = Self.normalizedInviteCode(code)
        return try await post(["invites", "redeem"], body: RedeemShareInviteRequest(code: normalized))
    }

    /// §7.5.5 code normalization: upper-case, then keep only `[A-Z0-9]`. Mirrors
    /// the design's entry field (`onboarding.jsx` `InviteCodeFlow` onChange), so a
    /// code pasted with a stray space or hyphen still redeems.
    static func normalizedInviteCode(_ raw: String) -> String {
        String(raw.uppercased().unicodeScalars.filter {
            $0.isASCII && (CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0))
        }.map(Character.init))
    }

    // MARK: - APNs device-token registration (MYR-186)
    //
    // Both verbs carry the SAME body and BOTH discard the response — see
    // ``PushDeviceEndpoint`` for why the token is a body field rather than a path
    // component, and why `sandbox` is the build's decision to make.

    /// `PUT /api/push/devices` (MYR-186) — register (upsert) this install's APNs
    /// token against the signed-in account. Authenticated via the standard
    /// pipeline (Bearer + single 401 refresh-retry); idempotent server-side.
    ///
    /// Returns `Void`: the contract's success is `200` with an empty-ish body
    /// carrying nothing the client needs, so this runs `performDiscardingBody`
    /// rather than decoding — a zero-byte `200` and a `{}` `200` are both success.
    public func registerPushDevice(token: String, sandbox: Bool) async throws {
        let body = try JSONEncoder().encode(PushDeviceRegistration(deviceToken: token, sandbox: sandbox))
        try await performDiscardingBody(
            ["push", "devices"],
            method: "PUT",
            body: body,
            allowTokenRefresh: true
        )
    }

    /// `DELETE /api/push/devices` (MYR-186) — forget this install's APNs token, so
    /// the next account signed in on this phone does not inherit the previous
    /// one's ride alerts. Same body as the register call; same discarded response.
    public func unregisterPushDevice(token: String, sandbox: Bool) async throws {
        let body = try JSONEncoder().encode(PushDeviceRegistration(deviceToken: token, sandbox: sandbox))
        try await performDiscardingBody(
            ["push", "devices"],
            method: "DELETE",
            body: body,
            allowTokenRefresh: true
        )
    }

    // MARK: - Request pipeline

    private func get<T: Decodable>(_ segments: [String], query: [URLQueryItem] = []) async throws -> T {
        try await perform(segments, query: query, method: "GET", body: nil, allowTokenRefresh: true)
    }

    /// `POST` with an optional JSON body (nil for the no-payload action
    /// endpoints). The body is encoded once and reused across the single 401
    /// refresh-retry so the provider's fresh token rides the same payload.
    private func post<T: Decodable>(_ segments: [String], body: (some Encodable)?) async throws -> T {
        let data = try body.map { try JSONEncoder().encode($0) }
        return try await perform(segments, query: [], method: "POST", body: data, allowTokenRefresh: true)
    }

    private func perform<T: Decodable>(
        _ segments: [String],
        query: [URLQueryItem] = [],
        method: String,
        body: Data?,
        allowTokenRefresh: Bool
    ) async throws -> T {
        let data = try await send(segments, query: query, method: method, body: body, allowTokenRefresh: allowTokenRefresh)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw RestError.decoding(underlying: error) }
    }

    /// The authenticated pipeline for endpoints whose 2xx body carries nothing the
    /// caller needs (MYR-186's push-device register/unregister). Identical
    /// transport, headers, 401 refresh-retry and typed error mapping as `perform`
    /// — it only skips the decode, which is the point: `perform` would fail a
    /// zero-byte `200` with `RestError.decoding`, so an endpoint documented as
    /// returning an "empty-ish" body must not go through it.
    ///
    /// Mirrors how `sendAuth` backs both `performAuth` and `performAuthNoContent`
    /// on the pre-auth pipeline.
    private func performDiscardingBody(
        _ segments: [String],
        query: [URLQueryItem] = [],
        method: String,
        body: Data?,
        allowTokenRefresh: Bool
    ) async throws {
        _ = try await send(segments, query: query, method: method, body: body, allowTokenRefresh: allowTokenRefresh)
    }

    /// Shared authenticated transport: build URL, guard transport, attach the
    /// Bearer token + optional JSON body, and either return the 2xx bytes or throw
    /// a typed `RestError`. Owns the single 401 refresh-retry (FR-6.2) so both
    /// `perform` and `performDiscardingBody` inherit it unchanged.
    private func send(
        _ segments: [String],
        query: [URLQueryItem] = [],
        method: String,
        body: Data?,
        allowTokenRefresh: Bool
    ) async throws -> Data {
        let url = try Self.buildURL(base: environment.restBaseURL, segments: segments, query: query)
        try validateTransport(url)

        // FR-6.1/6.2: fetch the token per request; on the 401 retry the provider
        // is asked again so it can hand back a freshly-refreshed value.
        let token = try await tokenProvider.token()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw RestError.transport(underlying: error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RestError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401 where allowTokenRefresh:
            // FR-6.2: do NOT retry with the same token — tell the provider the
            // token it vended was rejected (so a stateful provider forces a
            // refresh), refresh once, retry exactly once, then surface the typed
            // error on a second 401.
            await tokenProvider.invalidate(rejectedToken: token)
            return try await send(segments, query: query, method: method, body: body, allowTokenRefresh: false)
        default:
            throw Self.mapError(status: httpResponse.statusCode, data: data)
        }
    }

    /// Pre-auth POST for the §7.10 identity endpoints: a JSON body, NO Bearer
    /// header, NO 401 refresh-retry (see the auth MARK). Decodes the 2xx body.
    private func performAuth<T: Decodable>(_ segments: [String], body: some Encodable) async throws -> T {
        let (data, _) = try await sendAuth(segments, body: body, expectedEmpty: false)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw RestError.decoding(underlying: error) }
    }

    /// Pre-auth POST that expects `204 No Content` (revoke). Discards the body.
    private func performAuthNoContent(_ segments: [String], body: some Encodable) async throws {
        _ = try await sendAuth(segments, body: body, expectedEmpty: true)
    }

    /// Shared pre-auth transport: build URL, guard transport, POST the JSON body
    /// with no `Authorization` header, map non-2xx to a typed `RestError`.
    private func sendAuth(_ segments: [String], body: some Encodable, expectedEmpty: Bool) async throws -> (Data, HTTPURLResponse) {
        let url = try Self.buildURL(base: environment.restBaseURL, segments: segments, query: [])
        try validateTransport(url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw RestError.decoding(underlying: error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw RestError.transport(underlying: error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RestError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.mapError(status: httpResponse.statusCode, data: data)
        }
        return (data, httpResponse)
    }

    /// Compose the request URL by appending each path segment to the REST base
    /// and folding in query items. Path segments are percent-encoded by
    /// `appendingPathComponent`; query items by `URLComponents`. Throws
    /// `invalidResponse` if the composed URL is malformed (unreachable in
    /// practice — the segments are contract-fixed identifiers).
    private static func buildURL(base: URL, segments: [String], query: [URLQueryItem]) throws -> URL {
        let path = segments.reduce(base) { $0.appendingPathComponent($1) }
        guard !query.isEmpty else { return path }
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else {
            throw RestError.invalidResponse
        }
        components.queryItems = query
        guard let url = components.url else { throw RestError.invalidResponse }
        return url
    }

    private func validateTransport(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else { throw RestError.insecureTransport(url) }
        if scheme == "https" { return }
        if scheme == "http", environment.allowsInsecureLoopback {
            let host = url.host?.lowercased()
            if host == "localhost" || host == "127.0.0.1" || host == "::1" { return }
        }
        throw RestError.insecureTransport(url)
    }

    private static func mapError(status: Int, data: Data) -> RestError {
        struct Envelope: Decodable { let error: ErrorPayload }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .http(status: status, code: nil, message: nil, subCode: nil)
        }
        // `409 ride_active` (rest-api.md §7.8, MYR-230) is the ONE error whose body
        // augments the standard envelope with a sibling `activeRideRequest` — the
        // rider's existing open instant ride — so the client ADOPTS it instead of
        // surfacing a decline. The shared contracts `ErrorPayload.Code` enum does
        // not yet carry `ride_active` (it decodes to `.unrecognized("ride_active")`),
        // so match on the raw string — a later additive contracts entry keeps
        // working unchanged. The sibling decodes tolerantly through a local wrapper
        // over the contracts `RideRequest`; a body that omits it (terminal-race,
        // §7.8) yields `.rideActive(active: nil)` and the caller refetches its list.
        if status == 409, envelope.error.code.rawValue == "ride_active" {
            struct RideActiveEnvelope: Decodable { let activeRideRequest: RideRequest? }
            let active = (try? JSONDecoder().decode(RideActiveEnvelope.self, from: data))?.activeRideRequest
            return .rideActive(active: active)
        }
        return .http(
            status: status,
            code: envelope.error.code,
            message: envelope.error.message,
            subCode: envelope.error.subCode
        )
    }

    /// URLSession configuration per swift-lifecycle.md §4: waits for
    /// connectivity, 30s request / 60s resource timeouts.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }
}
