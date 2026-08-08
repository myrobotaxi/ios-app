// MARK: - RiderOwnLocationDot (MYR-483) — whose location is the rider's map about?
//
// External-beta product feedback, build `202608081012`, rider aboard a self-ride:
//
//   > *"Why is my location and when I'm in the car I don't need to see of my
//   > location"*
//
// His screenshot has the standard blue dot peeking out from under the gold car
// capsule. Once the rider is IN the car the two markers coincide by definition, so
// the dot carries no information the vehicle glyph does not already carry — and
// two markers arguing over one point reads as a rendering fault rather than as two
// facts. Uber suppresses it for exactly this window.
//
// **The pickup phases KEEP it**, and that is the whole reason this is a rule rather
// than a deletion: before boarding, *"where am I relative to the pickup point"* is
// the rider's main question, and the dot is the only thing on the map that answers
// it.
//
// The boundary is `TrackingLeg`, which is already the app's answer to "is the rider
// aboard": MYR-411 settled that `arrived` means the CAR IS AT THE KERB and the
// rider has not boarded (their own "Start ride" is the `arrived → enroute`
// transition), and `SharedViewerScreen.trackingLeg` maps `arrived` to `.toPickup`
// and `enroute`/`completed` to `.inRide`. So `.inRide` IS "aboard", derived from
// the ride's status rather than from a second list of statuses that could drift
// away from it.
//
// Pure and static so the rule is assertable — the inline tracking map and MYR-327's
// expanded viewer both read it, and a modifier on one of them would not be.
enum RiderOwnLocationDot {

    /// Whether the rider's own blue dot is drawn on the tracking map.
    ///
    /// - Parameters:
    ///   - authorized: `UserLocationProviding.showsUserLocationDot` — whether there
    ///     is a dot to draw at all. Unchanged and still the outer gate: this rule
    ///     can only ever take the dot AWAY, never grant it (in sim it is `false`,
    ///     which is what keeps every tracking capture byte-identical).
    ///   - leg: the tracking leg. `.inRide` is aboard.
    static func shows(authorized: Bool, leg: TrackingLeg) -> Bool {
        authorized && leg.isLeg1Active
    }
}
