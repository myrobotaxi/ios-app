import CoreLocation

// MARK: - MYR-379 — WHERE THE PIN-DROP OPENS
//
// THE CLIENT'S REPORT (High, r18): *"No option to type in pick up location and
// then fine set up exact spot to pick up on map. It locks to current location."*
//
// The second sentence is the whole of this file. Before MYR-379 the pin-drop's
// entry camera had exactly ONE input — `viewerState.userLocation.coordinate`,
// the device fix, handed to `PinDropOverlay.entryFix` at
// `SharedViewerScreen`'s map call site. There was no other way in, so the
// pin genuinely did lock to current location: a rider whose pickup was three
// blocks away had to drag there every single time, and a rider who had already
// confirmed a pin and came back to adjust it was returned to their own feet
// rather than to the pin they set.
//
// THE RULE IS A LADDER OVER THREE FACTS, and it is pure so the whole matrix can
// be pinned without a map, a camera or a location manager (`RiderPickupEntryTests`).
// `SharedViewerState.pinDropEntryCoordinate` is its only caller, so there is one
// definition of "where does the pin open" rather than one per surface.
//
//   1. A SEARCHED PICKUP AWAITING FINE-TUNING (`seed`) outranks everything. This
//      is the rung the client asked for: the rider typed a place, the flow is
//      chaining into the pin-drop to let them nudge it, and the searched
//      coordinate is the only thing that could possibly be meant. It is a
//      ONE-SHOT — `SharedViewerState` clears it on every exit from pin-drop
//      (confirm, back, reset), because a seed that outlived its session would
//      outrank rung 2 and silently undo a drag the rider had already committed.
//
//   2. A PICKUP ALREADY CONFIRMED (`confirmedPickup`) is where "On map" resumes.
//      ⚠️ THIS IS A DELIBERATE BEHAVIOUR CHANGE and it is named rather than
//      slipped in: before MYR-379, re-entering the pin-drop with a confirmed
//      pickup re-centred on the DEVICE FIX, discarding the pin the rider had
//      just set and making the "On map" affordance destructive to its own
//      result. That was defensible while a pickup could only ever be the device
//      fix nudged a little; it is indefensible once a pickup can be a place
//      across town. It is also the rung that keeps the search→fine-tune chain
//      coherent in BOTH directions — a rider who searched, nudged, confirmed,
//      then tapped "On map" again must land on their pickup, not start over.
//      **No DEBUG scene enters pin-drop holding a `draftPickup`** (`pinDrop`
//      seeds only a destination; `pinDropRealPath` seeds nothing at all), so
//      every drift-gate capture is byte-identical despite the change.
//
//   3. THE DEVICE FIX is what is left, and it is exactly what shipped before —
//      so a rider who has touched neither affordance gets the pre-MYR-379
//      camera, to the coordinate. That is the guarantee that makes this feature
//      additive: **"Current location" stays the default and nothing about it
//      moved.**
//
// `nil` out of all three is a real answer and not a failure: it is a simulated
// path with no seeded fix, where the map falls through to its own framing
// exactly as it always has.
/// MYR-379 — which END of the trip the search sheet's one results list is
/// currently about.
///
/// There is exactly ONE `PlaceSearching` seam per `SharedViewerState` (`let
/// placeSearch`), holding one `results` array behind one supersede generation.
/// Giving the pickup its own search stack would mean a second debounce, a
/// second throttle budget against Apple's per-device limit, a second resolver
/// and a second place for MYR-237's lessons to be re-learned. So the seam is
/// shared and the *target* is what moves: whichever field holds first
/// responder owns the list, and a row commits to that end of the trip.
///
/// This is also how Apple Maps and every ride-hailing app compose two
/// endpoints over one search — the results belong to the focused field — so
/// the grammar is borrowed rather than invented.
enum RideSearchField: Equatable, Sendable {
    case pickup
    case destination
}

enum RiderPickupEntry {

    /// Where the pin-drop's entry camera should seat — see the ladder above.
    ///
    /// Takes the three facts rather than `SharedViewerState`, so a test states a
    /// situation instead of building one.
    static func coordinate(
        seed: CLLocationCoordinate2D?,
        confirmedPickup: CLLocationCoordinate2D?,
        deviceFix: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        seed ?? confirmedPickup ?? deviceFix
    }

    /// Whether the entry coordinate came from somewhere OTHER than the device
    /// fix — i.e. whether this pin-drop session is about a place the rider
    /// named rather than about where they are standing.
    ///
    /// `SharedViewerState.enterPinDrop()` reads it to decide whether to ask the
    /// location seam for a fresh fix. That refresh exists (MYR-212 defect 2) so
    /// the pin opens on the freshest device coordinate rather than a stale one
    /// — which is precisely the wrong thing to do when the pin is deliberately
    /// NOT on the device: a fresh fix moving `mapRegionCenter` under a seeded
    /// session is the "it locks to current location" symptom coming back in
    /// through the one door left open.
    static func isPlaceLed(seed: CLLocationCoordinate2D?, confirmedPickup: CLLocationCoordinate2D?) -> Bool {
        seed != nil || confirmedPickup != nil
    }
}
