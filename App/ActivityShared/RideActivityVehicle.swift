import Foundation
import MyRobotaxiContracts

// MARK: - Which car is coming (MYR-398 v3)
//
// The v3 board's subline on the PICKUP LEG is the car's identification —
// `7SRJ294 · Silver Model Y` — which is the string Uber puts in the same slot and
// the one a rider standing at a kerb actually needs. v2 put the PICKUP PLACE there
// ("Sansome & Clay"), which tells a rider standing at Sansome & Clay where they
// are.
//
// ─────────────────────────────────────────────────────────────────────────────
// THESE ARE STATIC ATTRIBUTES, NOT CONTENT STATE, AND THAT IS THE WHOLE REASON
// THIS FEATURE NEEDS NO WIRE CHANGE.
//
// A ride's vehicle is fixed at accept time: §7.8 has no endpoint that re-assigns
// one, and a ride whose car changed would be a different ride. So the plate, the
// colour, the model, the year and the trim clear the bar `RideActivityAttributes`
// sets for a static field ("the fact genuinely CANNOT change for the life of the
// Activity") in the same way the ride id does — and putting them here means the
// server pushes nothing new, the content-state schema is untouched, and
// `RideActivityContentStateTests`' raw-key cross-pin is unaffected.
//
// The one thing that CAN change mid-ride is the owner editing the plate, which
// reaches the rider on the next `GET /api/vehicles` (MYR-286 records that there is
// no WS delta for it). An Activity already up keeps the plate it started with.
// That is the accepted cost of not pushing a P1 identification string ~40 times a
// ride, and it is the same trade §7.21.3 already made for the pickup label.
// ─────────────────────────────────────────────────────────────────────────────

/// The five identification facts, as they arrive off `GET /api/vehicles`.
///
/// RAW PARTS, NOT A COMPOSED STRING. The grammar is presentation and belongs with
/// the rest of the copy (`RideActivityVehicleDescriptor` below); the parts are
/// facts. Carrying the sentence instead would freeze a wording into every Activity
/// in flight and make the copy untestable against anything but itself.
///
/// Every field is optional and the whole value is optional on the attributes, for
/// the reason `pickupLabel` was: an Activity started by a build that predates this
/// type is DECODED by the system after an app update, and a non-optional addition
/// would fail that decode and take a live ride's card off the lock screen on
/// upgrade day.
struct RideActivityVehicle: Codable, Hashable, Sendable {
    /// The owner-entered plate (`VehicleSummary.licensePlate`, contracts 0.15.0),
    /// verbatim.
    ///
    /// **NEVER THE `VIN ····2046` DEGRADE.** `VehicleContractMapping.plateDisplay`
    /// is right for the Booking chip, which is a labelled box that would otherwise
    /// be empty; it is wrong here, where the plate is a bare segment of a sentence.
    /// The board's rule is that a missing plate DROPS the `{plate} · ` segment —
    /// "Silver Model Y" is a true and useful line, and "VIN ····2046 · Silver Model
    /// Y" is four characters of hex nobody can read off a bumper.
    var plate: String?

    /// `VehicleSummary.color` — "Silver", "Quicksilver".
    var color: String?

    /// `VehicleSummary.model` — "Model Y". The bare model, never the composed
    /// "{year} {model} {trim}" line: the year is a separate field here so the
    /// descriptor's ladder can drop it without re-parsing a string.
    var model: String?

    /// `VehicleSummary.year`.
    var year: Int?

    /// The DISPLAY-READY trim (`VehicleState.trimLabel`, MYR-320) — "Performance",
    /// never the raw `trim` badge "p74d".
    ///
    /// ⚠️ **NOT AVAILABLE TO A RIDER TODAY, AND THAT IS A CONTRACT FACT RATHER THAN
    /// AN OMISSION HERE.** `trimLabel` lives on `VehicleState`, the owner's
    /// SNAPSHOT; the rider reads `GET /api/vehicles`, whose `VehicleSummary`
    /// carries no trim of any kind (checked against contracts 0.27.0). So the field
    /// is wired end to end and populated by nothing on the rider path — which is
    /// why the descriptor's ladder is written to include it rather than to assume
    /// it, and why `year` is the enrichment that actually reaches the card today.
    var trim: String?

    init(plate: String? = nil, color: String? = nil, model: String? = nil, year: Int? = nil, trim: String? = nil) {
        self.plate = plate
        self.color = color
        self.model = model
        self.year = year
        self.trim = trim
    }

    /// Read the five facts off the rider's own `GET /api/vehicles` row.
    ///
    /// Lives here rather than in `LiveFleetMemberMapping` because the widget target
    /// links the contracts module and does not link the app's mapping layer, and
    /// because this is a straight field read with no policy in it — the policy is
    /// all in `RideActivityVehicleDescriptor`.
    init(summary: VehicleSummary) {
        self.init(
            plate: summary.licensePlate,
            color: summary.color,
            model: summary.model,
            year: summary.year,
            // contracts 0.27.0's `VehicleSummary` has no trim field at all. Spelled
            // as an explicit `nil` rather than left out, so the day the list row
            // grows one this is the line that changes.
            trim: nil
        )
    }
}

// MARK: - `{plate} · {color} {model}`

/// The board's subline grammar for the pickup leg, as a pure rule.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// **THE CLIENT ASKED FOR YEAR AND TRIM TO BE FOLDED IN "WHERE IT FITS ONE LINE",
/// SO WHAT FITS IS A LADDER RATHER THAN A FIXED STRING.**
///
/// The line is `lineLimit(1)` with a tail ellipsis in a 320pt slot, and the thing
/// it would ellipsize is the MODEL — the second most identifying fact on the card.
/// So the descriptor drops parts itself, in the order they are least useful to
/// somebody looking for a car at a kerb, and never lets the truncation choose:
///
///   1. `7SRJ294 · Silver 2026 Model Y Performance`  — everything
///   2. `7SRJ294 · Silver 2026 Model Y`              — trim goes first
///   3. `7SRJ294 · Silver Model Y`                   — then the year
///   4. `7SRJ294 · Model Y`                          — then the colour
///
/// The plate and the model are never dropped: the plate is the only fact that
/// distinguishes two identical cars, and a line with no model is not a description
/// of a car. With no plate the same ladder runs without the `{plate} · ` segment,
/// which is why a car whose owner never entered one still reads
/// `Silver 2026 Model Y Performance` — the ladder's own budget is what buys the
/// trim back.
///
/// **THE BUDGET IS A COPY RULE, AND THE MEASUREMENT IS THE GUARD.** 34 characters
/// is a judgement about how much identification is worth reading at a glance, not
/// a fitting constant — the slot holds appreciably more. What a test can prove is
/// the direction that matters: that the widest string this budget can emit does
/// NOT truncate in the real slot at the real size
/// (`RideActivityVehicleDescriptorTests.testTheBudgetsWidestStringFitsTheSubline`).
/// A character count cannot answer "does it fit"; a measurement cannot answer "is
/// it worth reading". Both questions are asked, in the place that can answer each.
/// ─────────────────────────────────────────────────────────────────────────────
enum RideActivityVehicleDescriptor {

    /// The longest descriptor this rule will emit before it starts dropping parts.
    static let maxCharacters = 34

    /// Compose the pickup leg's subline.
    ///
    /// Falls back to `RideActivityCopy.genericVehicleName` — "Your Tesla" — when
    /// every fact is missing, which is the board's own nameless-vehicle rule. It is
    /// deliberately NOT the wire's `vehicleName`: that is the owner's NICKNAME
    /// ("Lunar"), which is a name for the car and not a description of it, and a
    /// rider at a kerb cannot match it against anything they can see.
    static func compose(_ vehicle: RideActivityVehicle?) -> String {
        let plate = nonEmpty(vehicle?.plate)
        let color = nonEmpty(vehicle?.color)
        let model = nonEmpty(vehicle?.model)
        let trim = nonEmpty(vehicle?.trim)
        let year = vehicle?.year.flatMap { $0 > 0 ? String($0) : nil }

        let cars: [String] = [
            [color, year, model, trim],
            [color, year, model],
            [color, model],
            [model],
        ]
        .map { $0.compactMap { $0 }.joined(separator: " ") }
        .filter { !$0.isEmpty }

        let candidates: [String]
        if cars.isEmpty {
            // No words about the car at all. A bare plate is still identification
            // and is still true; it is only when there is nothing whatsoever that
            // the generic name is the honest answer.
            candidates = plate.map { [$0] } ?? []
        } else {
            candidates = cars.map { car in plate.map { "\($0) · \(car)" } ?? car }
        }

        guard let plainest = candidates.last else { return RideActivityCopy.genericVehicleName }
        return candidates.first { $0.count <= maxCharacters } ?? plainest
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
