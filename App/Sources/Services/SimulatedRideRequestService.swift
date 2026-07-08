import Foundation
import Observation

// MARK: - M1 implementation of the ride-request seam (MYR-171)
//
// A local state machine + timers, no network — see `RideRequestService`'s
// header comment for the seam's contract and why one instance is shared
// across both roles. Mirrors `SimulatedVehicleTelemetrySource`'s shape
// (VehicleTelemetry.swift): private `Timer`s, `nonisolated(unsafe)` storage
// for them (only ever touched on the main actor except in `deinit`, which
// Swift always runs nonisolated even for `@MainActor` classes), idempotent
// `start`/`stop`-style lifecycle per timer.
@Observable
@MainActor
public final class SimulatedRideRequestService: RideRequestService {
    public private(set) var activeRequest: RideRequestRecord?

    private nonisolated(unsafe) var autoAcceptTimer: Timer?
    private nonisolated(unsafe) var progressTimer: Timer?

    public init() {}

    deinit {
        autoAcceptTimer?.invalidate()
        progressTimer?.invalidate()
    }

    public func submit(_ input: RideRequestInput) {
        autoAcceptTimer?.invalidate()
        progressTimer?.invalidate()
        activeRequest = RideRequestRecord(input: input, status: .pending)

        // Fallback for a solo rider-only demo: if nobody plays the owner role
        // and accepts manually, the request still resolves — see
        // `RideRequestTiming`'s doc comment and ride-request.jsx:1112-1117.
        let totalDelay = RideRequestTiming.sendFillDuration
            + RideRequestTiming.sentHoldDuration
            + RideRequestTiming.minimizeToAutoAcceptDelay
        let requestID = activeRequest?.id
        let timer = Timer(timeInterval: totalDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.autoAccept(requestID: requestID) }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoAcceptTimer = timer
    }

    public func accept() {
        autoAcceptTimer?.invalidate()
        autoAcceptTimer = nil
        guard var request = activeRequest, request.status == .pending else { return }
        request.status = .accepted
        request.acceptedAt = Date()
        // Scheduled requests are reservations for later — no live trip to
        // simulate now (ride-request.jsx `commitSchedule` returns the rider
        // straight to idle; the owner's dispatch happens at the scheduled
        // time, out of M1's simulated-now scope). Only "now" requests start
        // the tracking progress ticker.
        if request.input.schedule == nil {
            request.trackProgress = RideRequestTiming.autoAcceptInitialProgress
        }
        activeRequest = request
        if request.input.schedule == nil {
            startProgressTicking()
        }
    }

    public func decline() {
        autoAcceptTimer?.invalidate()
        autoAcceptTimer = nil
        guard var request = activeRequest, request.status == .pending else { return }
        request.status = .declined
        activeRequest = request
    }

    public func cancel() {
        autoAcceptTimer?.invalidate()
        autoAcceptTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        activeRequest = nil
    }

    public func completeAndReset() -> RequestedRide? {
        guard let request = activeRequest, request.isArrived else { return nil }
        progressTimer?.invalidate()
        progressTimer = nil
        let ride = Self.buildRequestedRide(from: request)
        activeRequest = nil
        return ride
    }


    // MARK: Private

    private func autoAccept(requestID: String?) {
        guard let request = activeRequest, request.id == requestID, request.status == .pending else { return }
        accept()
    }

    private func startProgressTicking() {
        progressTimer?.invalidate()
        let tickInterval: TimeInterval = 1.0 / 10.0
        let step = tickInterval / RideRequestTiming.trackingDemoDuration
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickProgress(by: step) }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func tickProgress(by step: Double) {
        guard var request = activeRequest, var progress = request.trackProgress else {
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }
        progress = min(1, progress + step)
        request.trackProgress = progress
        activeRequest = request
        if progress >= 1 {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    /// Builds the `RequestedRide` history record from a finished trip —
    /// shape/fields per `RideHistoryFixtures.requestedRides`
    /// (shared-screens.jsx:8-13 `REQUESTED_RIDES`). `rel`/`driver`/`vehicle`
    /// come from the chosen `FleetMember` — `ReviewContent`'s `sel` doesn't
    /// carry `rel` on its own, so this looks it up the same way the MYR-171
    /// research notes flagged.
    private static func buildRequestedRide(from request: RideRequestRecord) -> RequestedRide {
        let fleetMember = request.input.fleetMember
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return RequestedRide(
            id: "req-\(request.id)",
            day: "Today",
            date: request.requestedAt.formatted(.dateTime.month(.abbreviated).day()),
            from: request.input.pickup.label,
            to: request.input.destination.label,
            driver: fleetMember.owner,
            relationship: fleetMember.relationship,
            vehicle: fleetMember.name,
            start: formatter.string(from: request.requestedAt),
            miles: request.input.destination.miles,
            mins: request.input.destination.minutes,
            passenger: request.input.passenger
        )
    }
}
