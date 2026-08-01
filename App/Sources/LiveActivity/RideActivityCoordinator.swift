import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - The performer (MYR-172)
//
// Owns the side effects and none of the decisions: every "should we?" comes from
// `RideActivityStateMachine.action`, and this type's whole job is to carry that
// out and to keep the server's copy of the push token current.
//
// Modelled on `PushRegistrationCoordinator` (MYR-186) down to the composition
// rule: in simulated mode it is built INERT (`endpoint: nil`, `isLive: false`)
// rather than optional, so no call site has to remember to check — which is what
// keeps every simulated and DEBUG-scene capture byte-identical.

@MainActor
@Observable
final class RideActivityCoordinator {
    private let presenter: any RideActivityPresenting
    private let endpoint: (any RideActivityTokenEndpoint)?
    private let sandbox: Bool
    private let isLive: Bool

    /// Resolves the rider's current vehicle nickname for the LOCAL start frame
    /// only. Every subsequent frame prefers the wire's `vehicleName`, which is
    /// authoritative — see `RideActivityStateMachine.contentState`.
    private let vehicleName: @MainActor () -> String

    private(set) var phase: RideActivityPhase = .idle

    /// The token last successfully registered, and the ride it was registered
    /// against. BOTH halves matter: the same token may never be re-registered for
    /// the same ride (a wasted round trip on every foreground), but it absolutely
    /// must be re-registered for a DIFFERENT ride, since the server keys the
    /// registration on `(ride, rider)`.
    private var registered: (token: String, rideID: String)?

    private var tokenTask: Task<Void, Never>?

    init(
        presenter: any RideActivityPresenting,
        endpoint: (any RideActivityTokenEndpoint)?,
        isLive: Bool,
        sandbox: Bool = PushEnvironment.isSandbox,
        vehicleName: @escaping @MainActor () -> String = { "" }
    ) {
        self.presenter = presenter
        self.endpoint = endpoint
        self.isLive = isLive
        self.sandbox = sandbox
        self.vehicleName = vehicleName
    }

    // MARK: - The one entry point

    /// Called whenever the rider's active ride changes — including to `nil`.
    ///
    /// `nil` is a real input, not a missing one: a remotely CANCELLED ride is
    /// erased rather than transitioned, so disappearance is the only signal the
    /// client gets that the ride is over. Treating it as "nothing to do" would
    /// leave a card on the lock screen for a ride that no longer exists.
    func handleRideChange(_ record: RideRequestRecord?) async {
        // Simulated mode never touches ActivityKit. The fixture ride would put a
        // real card on a real lock screen describing a ride that is not happening.
        guard isLive else { return }

        let action = RideActivityStateMachine.action(
            phase: phase,
            record: record,
            vehicleName: vehicleName()
        )

        switch action {
        case .none:
            return

        case .start(let rideID, let state):
            await performStart(rideID: rideID, state: state, pickupLabel: pickupLabel(of: record))

        case .update(let rideID, let state):
            await presenter.update(state: state, staleDate: RideActivityStaleness.date())
            phase = .live(rideID: rideID, state: state)

        case .end(let rideID, let state, let dismissal):
            await performEnd(rideID: rideID, state: state, dismissal: dismissal)

        case .restart(let endingRideID, let endingState, let rideID, let state):
            await performEnd(rideID: endingRideID, state: endingState, dismissal: .immediate)
            await performStart(rideID: rideID, state: state, pickupLabel: pickupLabel(of: record))
        }
    }

    /// The rider's own label for where the car is collecting them — the MYR-398
    /// "Meet at {pickup}" line, read off the ride record the Activity is being
    /// started FROM.
    ///
    /// It is a STATIC attribute rather than a pushed field on the contract's own
    /// instruction (§7.21.3): a pickup cannot change for the life of a ride, so
    /// pushing it would repeat a P1 place label ~40 times a ride to tell the phone
    /// a string it typed in itself. This accessor is the one place the app answers
    /// it, and it answers `nil` — never `""` — when there is nothing to name, so
    /// the card renders no meet-at line rather than "Meet at ".
    private func pickupLabel(of record: RideRequestRecord?) -> String? {
        let label = record?.input.pickup.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty ?? true) ? nil : label
    }

    /// Signing out ends the Activity at once. A lock-screen card naming a
    /// destination (P1) must not outlive the session that was allowed to see it.
    func handleSignOut() async {
        guard case .live(let rideID, let state) = phase else { return }
        await performEnd(rideID: rideID, state: state, dismissal: .immediate)
    }

    // MARK: - Effects

    private func performStart(
        rideID: String,
        state: RideActivityAttributes.ContentState,
        pickupLabel: String?
    ) async {
        let started = await presenter.start(
            attributes: RideActivityAttributes(rideID: rideID, pickupLabel: pickupLabel),
            state: state,
            staleDate: RideActivityStaleness.date()
        )
        // A refusal is ordinary — the rider may simply have Live Activities off.
        // The phase stays `.idle`, so nothing is registered and nothing is ended,
        // and the app's own in-app tracking sheet carries the ride as it always
        // has.
        guard started else { return }

        phase = .live(rideID: rideID, state: state)
        observeTokens(for: rideID)
    }

    private func performEnd(
        rideID: String,
        state: RideActivityAttributes.ContentState,
        dismissal: RideActivityDismissal
    ) async {
        tokenTask?.cancel()
        tokenTask = nil
        registered = nil
        phase = .idle

        await presenter.end(state: state, dismissal: dismissal)

        // Tell the server the Activity is gone so it stops pushing to a token that
        // no longer addresses anything. Idempotent by contract, and a failure here
        // is genuinely not worth reacting to: the registration dies with the ride
        // server-side anyway, and the card is already off the rider's screen.
        try? await endpoint?.endRideActivityToken(rideID: rideID)
    }

    // MARK: - Push token

    /// Consume the Activity's token stream for as long as it lives.
    ///
    /// Every element is registered, not just the first — ActivityKit REISSUES the
    /// token mid-Activity and expects the server to switch. A rotation is an
    /// ordinary re-registration (the endpoint upserts on `(ride, rider)`), so there
    /// is nothing special to do beyond noticing it.
    private func observeTokens(for rideID: String) {
        tokenTask?.cancel()
        let stream = presenter.pushTokens()
        tokenTask = Task { [weak self] in
            for await token in stream {
                guard !Task.isCancelled else { return }
                await self?.register(token: token, rideID: rideID)
            }
        }
    }

    private func register(token: Data, rideID: String) async {
        guard let endpoint else { return }

        // Hex, via MYR-186's encoder rather than a second one. The server validates
        // hex, and `Data.description` — the shape a naive interpolation produces —
        // is `<8a1f4c2e …>`, which is not it.
        let hex = PushDeviceToken.hex(from: token)

        if let registered, registered.token == hex, registered.rideID == rideID { return }

        do {
            _ = try await endpoint.registerRideActivityToken(
                rideID: rideID,
                token: hex,
                sandbox: sandbox
            )
            registered = (token: hex, rideID: rideID)
        } catch let error as RestError where error.isTerminalRideActivityConflict {
            // §7.21: a 409 means the ride is already terminal, "and the 409 is the
            // signal to end it locally". This is the ONLY thing that can rescue a
            // rider whose ride ended while the app was not running to see it.
            //
            // The final frame is the last one we had, with its status UNCHANGED,
            // and the dismissal is immediate. We deliberately do not guess: the
            // server told us the ride is over but not HOW it ended, and writing
            // "You've arrived" over a ride that was cancelled is a worse lock
            // screen than one that disappears promptly. If the app's own record
            // catches up a moment later, the state machine ends it properly — but
            // by then there is nothing left to end, which is the correct outcome.
            guard case .live(_, let last) = phase else { return }
            await performEnd(rideID: rideID, state: last, dismissal: .immediate)
        } catch {
            // Anything else is transient. Leave `registered` unset so the next
            // rotation — or the next start — tries again. Retrying here would
            // fight the server's own backoff for no benefit: pushes are the
            // primary channel but the app is the backstop, and the backstop is
            // still standing.
            return
        }
    }
}
