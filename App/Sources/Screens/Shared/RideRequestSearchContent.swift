import SwiftUI
import DesignSystem
#if canImport(UIKit)
import UIKit
#endif

// MYR-200 search-gap fix — height probes so the sheet can hug its content up
// to the 712pt cap (see `RideRequestSearchContent.scrollRegionHeight`).
private struct SearchHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct SearchResultsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - RideRequestSearchContent (MYR-171, design/app/ride-request.jsx
// SearchContent 150-346 + PassengerPicker 94-143)
//
// Search phase: Now/Schedule + Me/Someone else chips, the pickup/destination
// route card, and Saved/Recent/Nearby (or filtered Results) below. Schedule
// picking opens a slide-up card (`RideSlideUpCard`) — the same recipe
// `ScheduledRideSheet`'s reschedule mode uses for its day/time chips, reused
// here rather than forked.
struct RideRequestSearchContent: View {
    @Bindable var viewerState: SharedViewerState
    /// MYR-236 round 4: rendered inside the `PanSheet` engine (rider idle↔search
    /// continuous drag). When true the engine owns the bottom-pin + the drag-to-
    /// dismiss gesture, so the chrome is un-pinned and the grab handle is
    /// decorative. When false (never, in the shipping app — search is always
    /// engine-hosted now) it renders standalone exactly as before.
    var hosted: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var forSomeoneElse = false
    @State private var scheduleSheetOpen = false
    @State private var schedDay = "Today"
    @State private var schedTime = "5:30 PM"

    // MYR-215 deliverable 3: the destination chosen on this sheet, pending an
    // explicit "Continue". Non-nil ⇒ the field is filled, the results list gives
    // way to the CTA, and the flow has NOT advanced. Editing the field clears it
    // (back to search-as-you-type). Mirrors `viewerState.draftDestination` but
    // kept local so the field/CTA presentation is a pure view concern.
    @State private var pickedDestination: RidePlace?
    @FocusState private var destinationFieldFocused: Bool

    /// MYR-216 deliverable 1 — the collapse trigger: true once a destination is
    /// chosen (CTA state). Drives the animated sheet resize down/up.
    private var isChoosing: Bool { pickedDestination != nil }

    // MYR-200 search-gap fix — measured heights that let the sheet size to its
    // content up to the 712pt cap (see `scrollRegionHeight`).
    @State private var headerHeight: CGFloat = 0
    @State private var resultsHeight: CGFloat = 0

    /// TRUE root cause of the "dead zone below the last list row" (3 prior
    /// rounds missed it): the sheet was pinned to a FIXED
    /// `rideRequestSearchSheetHeight` (712) regardless of how many rows the
    /// list held, and the inner `ScrollView` — always greedy along its axis —
    /// stretched to fill it. Whenever the list was shorter than the sheet
    /// (any filtered result set, and the prototype's own default list once
    /// scrolled), everything below the last row was empty black sheet. The
    /// prototype has the identical void (measured in the browser: a single
    /// filtered result leaves ~437pt of empty sheet below it), so matching
    /// the jsx verbatim reproduced the bug rather than fixing it.
    ///
    /// Fix: cap the scroll region at exactly the space left inside the 712pt
    /// envelope (`712 − topPad − bottomPad − header`), then let the SHEET hug
    /// `min(list content, that cap)`. A full list still fills to 712 and
    /// scrolls (identical to before, faithful to the prototype's default);
    /// a short list produces a short sheet whose last row sits the SAME 100pt
    /// above the physical bottom the prototype's list bottom inset measures —
    /// no void, in every case.
    private var scrollRegionHeight: CGFloat {
        Self.scrollRegionHeight(
            isLive: viewerState.isLiveLocation,
            headerHeight: headerHeight,
            resultsHeight: resultsHeight
        )
    }

    /// Pure height derivation (MYR-215 defect 1) — extracted so the
    /// stable-vs-hug choice is unit-testable without mounting the view.
    ///
    /// In LIVE mode the search phase holds ONE stable height — the full 712
    /// envelope — so the sheet frame never JUMPS when the first keystroke swaps
    /// the calm pre-typing region for filtered results (the client's report:
    /// "start at that height and fill in the filtered results as I type").
    /// Pre-typing there's no fixture Saved/Recent list to fill it (MYR-214 hides
    /// those in live), so the MYR-200 hug-to-content path would open the sheet
    /// SHORT, then snap tall on the first result — exactly the jump. Pinning the
    /// scroll region to `available` keeps the frame put; results populate in
    /// place inside it, so the returned height is INDEPENDENT of `resultsHeight`.
    ///
    /// SIM keeps MYR-200's hug-to-content behavior (a full fixture list fills
    /// 712 and scrolls; a filtered set shrinks with no dead zone below the last
    /// row), so every sim search/searchFiltered scene stays pixel-identical.
    static func scrollRegionHeight(isLive: Bool, headerHeight: CGFloat, resultsHeight: CGFloat) -> CGFloat {
        let available = MRTMetrics.rideRequestSearchSheetHeight
            - 6 // .padding(.top, 6)
            - MRTMetrics.homeSheetContentBottomPadding
            - headerHeight
        guard available > 0 else { return 0 }
        return isLive ? available : min(resultsHeight, available)
    }

    /// The fleet owner the search phase is provisionally requesting from —
    /// not yet chosen by the rider (that's Review's fleet picker), so this
    /// mirrors the jsx's `requesterName` default: the first shared Tesla
    /// (ride-request.jsx:150 `requesterName = 'Alex'`).
    private var requesterName: String {
        RideRequestFixtures.fleet.first { $0.id == viewerState.draftFleetMemberID }?.owner
            ?? RideRequestFixtures.fleet[0].owner
    }

    // MYR-211: results now come from the `PlaceSearching` seam
    // (`viewerState.placeSearch`) — `SimulatedPlaceSearch` runs the identical
    // fixture filter this computed property used to, `LivePlaceSearch` runs
    // region-biased MapKit autocomplete. Same tri-state contract: `nil` → show
    // Saved/Recent/Nearby, `[]` → "No results", `[…]` → the Results list.
    private var searchResults: [RidePlace]? { viewerState.placeSearch.results }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (handle + chips + route) — measured so the scroll region
            // below can be capped to the remaining space inside the 712pt
            // envelope (MYR-200 search-gap fix, see `scrollRegionHeight`).
            VStack(alignment: .leading, spacing: 0) {
                // MYR-199 fix: drag-down-to-dismiss — ride-request.jsx:1150
                // `d > 36 && phase === 'search'` → `closeToIdle()` (full draft
                // reset back to the greeting sheet).
                // MYR-236 round 4: engine-hosted → decorative handle (the
                // PanSheet pan owns drag-to-collapse, which commits
                // `resetDraftToIdle()` at settle). Standalone → the self-
                // contained drag-down-to-dismiss handle (MYR-199).
                RideGrabHandle(onDragDismiss: hosted ? nil : {
                    dismissKeyboardBeforeLeaving() // MYR-239 defect 2
                    viewerState.resetDraftToIdle()
                })
                chipRow
                    .padding(.bottom, viewerState.draftSchedule != nil ? 8 : 12)
                if let schedule = viewerState.draftSchedule {
                    scheduleRow(schedule)
                        .padding(.bottom, 12)
                }
                if forSomeoneElse {
                    passengerPicker
                        .padding(.bottom, 12)
                }
                routeCard
                    .padding(.bottom, 10)
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: SearchHeaderHeightKey.self, value: geo.size.height)
            })

            // Below the header: the results list (search-as-you-type), or — once
            // a destination is chosen (MYR-215 deliverable 3) — the "Continue"
            // CTA in its place.
            belowHeaderRegion
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, MRTMetrics.homeSheetContentBottomPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onPreferenceChange(SearchHeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(SearchResultsHeightKey.self) { resultsHeight = $0 }
        .rideRequestSheetChrome(pinned: !hosted)
        // MYR-216 deliverable 1: one deliberate animated resize when the sheet
        // collapses onto its content on selection (and expands back on
        // edit/clear) — the same settle curve the phase transitions use
        // (SharedViewerScreen, ride-request.jsx:1185). Keyed on the chosen-state
        // so it never fires per keystroke while typing.
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.42), value: isChoosing)
        .overlay {
            if scheduleSheetOpen {
                scheduleSlideUpCard
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34), value: scheduleSheetOpen)
        .onChange(of: query) { _, newValue in
            // MYR-215 deliverable 3: editing the filled field returns to
            // search-as-you-type — clear the pending choice (unless this is our
            // own programmatic fill of the exact chosen label on select).
            if let picked = pickedDestination, newValue != picked.label {
                pickedDestination = nil
                viewerState.clearChosenDestination()
            }
            viewerState.updateSearch(query: newValue)
        }
        // MYR-211 region-bias fix (live-audit defect): a search issued BEFORE
        // the first location fix (the permission prompt is still up on first
        // launch; the `searchFiltered` scene seeds its query on appear)
        // captured the fixture-fallback center and produced globally-unbiased,
        // SF-distanced results. Re-run the active query whenever the region
        // center changes (first fix / device movement / live-vehicle fallback
        // arriving) so results re-bias + re-distance. Sim: the center is a
        // constant, this never fires — pixel-identical.
        .onChange(of: viewerState.mapRegionCenterKey) { _, _ in
            guard !query.isEmpty else { return }
            viewerState.updateSearch(query: query)
        }
        .onAppear {
            // MYR-239 defect 2 — re-entering Search (back from pin-drop/review)
            // must NOT restore the destination field's first responder mid-
            // transition: keep focus down so the keyboard only returns when the
            // rider taps the field, after the sheet has finished laying out.
            destinationFieldFocused = false
            forSomeoneElse = viewerState.draftPassenger != nil
            if let schedule = viewerState.draftSchedule {
                schedDay = schedule.day
                schedTime = schedule.time
            }
            #if DEBUG
            if let debugQuery = DebugScene.current?.searchQuery { query = debugQuery } // MYR-200 searchFiltered scene
            #endif
            // MYR-215 deliverable 3: re-entering Search with a destination already
            // chosen (e.g. bouncing back from pin-drop, or a declined rebook)
            // reflects it as filled + Continue, not an empty field. A debug query
            // (searchFiltered) takes precedence — it drives the search-as-you-type
            // capture.
            if query.isEmpty, let dest = viewerState.draftDestination {
                pickedDestination = dest
                query = dest.label
            }
            // MYR-211 — seed the search backend with the (possibly debug-set)
            // query so the seam's `results` match the field on first render.
            viewerState.updateSearch(query: query)
        }
    }

    // MARK: Chips

    private var chipRow: some View {
        HStack(spacing: 7) {
            RideChip(title: "Now", selected: viewerState.draftSchedule == nil) {
                viewerState.draftSchedule = nil
            }
            RideChip(title: "Schedule", selected: viewerState.draftSchedule != nil) {
                if let schedule = viewerState.draftSchedule {
                    schedDay = schedule.day
                    schedTime = schedule.time
                }
                scheduleSheetOpen = true
            }
            Rectangle().fill(Color.mrtBorder).frame(width: MRTMetrics.hairline, height: 16)
                .padding(.horizontal, 3)
            RideChip(title: "Me", selected: !forSomeoneElse) {
                forSomeoneElse = false
                viewerState.draftPassenger = nil
            }
            RideChip(title: "Someone else", selected: forSomeoneElse) {
                forSomeoneElse = true
            }
            Spacer(minLength: 0)
        }
    }

    private func scheduleRow(_ schedule: RideSchedule) -> some View {
        Button {
            schedDay = schedule.day
            schedTime = schedule.time
            scheduleSheetOpen = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                (Text("Pickup ") + Text("\(schedule.day) \u{00B7} \(schedule.time)").foregroundColor(Color.mrtText).fontWeight(.semibold))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.mrtTextSec)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mrtGold)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 30)
    }

    // MARK: Passenger picker (ride-request.jsx:94-143)

    private var passengerName: String { viewerState.draftPassenger?.name ?? "" }
    private var passengerPhone: String { viewerState.draftPassenger?.phone ?? "" }

    private var passengerNameBinding: Binding<String> {
        Binding(
            get: { passengerName },
            set: { newValue in setPassenger(name: newValue, phone: passengerPhone) }
        )
    }

    private var passengerPhoneBinding: Binding<String> {
        Binding(
            get: { passengerPhone },
            set: { newValue in setPassenger(name: passengerName, phone: newValue) }
        )
    }

    private func setPassenger(name: String, phone: String) {
        viewerState.draftPassenger = (name.isEmpty && phone.isEmpty) ? nil : RidePassenger(name: name, phone: phone)
    }

    private var passengerPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RideEyebrowText(text: "Passenger")
                Spacer(minLength: 0)
                if !passengerName.isEmpty {
                    Button("Clear") { viewerState.draftPassenger = nil }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mrtGold)
                        .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 10)

            // MYR-228 — the recent-passenger chips render fixture PEOPLE
            // (`RideRequestFixtures.recentPassengers`). There is no contacts /
            // recent-passengers backend, so in live mode hide the chip row
            // entirely — the rider types a name + number manually below (the
            // honest, backend-free path). SIM keeps the chips (pixel-identical).
            if !viewerState.isLiveLocation {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RideRequestFixtures.recentPassengers) { contact in
                            let active = passengerPhone == contact.phone
                            Button {
                                setPassenger(name: contact.name, phone: contact.phone)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(Color.mrtElevated).frame(width: 24, height: 24)
                                        .overlay(Text(initials(contact.name)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.mrtText))
                                    Text(contact.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .tracking(-0.1)
                                        .foregroundStyle(active ? Color.mrtGold : Color.mrtText)
                                }
                                .padding(.leading, 6)
                                .padding(.trailing, 12)
                                .padding(.vertical, 6)
                                .background(active ? Color.mrtGoldTileFaint : Color.mrtRideChipFill, in: Capsule())
                                .overlay(Capsule().strokeBorder(active ? Color.mrtGold.opacity(Double(0x66) / 255.0) : Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .padding(.bottom, 11)
            }

            VStack(spacing: 8) {
                TextField("Passenger name", text: passengerNameBinding)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.mrtRequestCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                TextField("Mobile number", text: passengerPhoneBinding)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .keyboardType(.phonePad)
                    .foregroundStyle(Color.mrtText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.mrtRequestCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "paperplane.fill").font(.system(size: 12)).foregroundStyle(Color.mrtGold)
                notifyNote
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineSpacing(2)
            }
            .padding(.top, 11)
        }
        .padding(14)
        .mrtSurface(.control, fill: .mrtElevated, radius: 16)
    }

    private var notifyNote: Text {
        let first = passengerName.split(separator: " ").first.map(String.init) ?? "them"
        return Text("We\u{2019}ll text ")
            + Text(passengerName.isEmpty ? "them" : first).foregroundColor(Color.mrtText).fontWeight(.semibold)
            + Text(" a live tracking link as soon as \(requesterName) accepts.")
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    // MARK: Route card (pickup / destination)
    //
    // MYR-197 fix: the pickup→destination connector used to be a `flex:1`
    // `Rectangle().frame(maxHeight: .infinity)` sitting as an HStack sibling
    // next to the content column. With no fixed-height frame between this
    // card and the screen-height `GeometryReader`/`ZStack` in
    // `SharedViewerScreen`, that "give me infinity" request propagated all
    // the way up — this card (and the whole Search sheet's internal layout)
    // rendered with a huge dead gap instead of hugging its content (client
    // QA, MYR-197). Fix: paint the dot/line rail as a `.background` behind
    // the content column instead of a flexible HStack sibling — a
    // `.background` is always proposed a size equal to the *already
    // resolved* size of the view it's attached to, so the connector's own
    // `maxHeight: .infinity` correctly fills exactly the content column's
    // natural height (pickup row top → destination row bottom) and nothing
    // more, matching the jsx's CSS `align-items: stretch` behavior. Ported
    // to `RideRequestBookingContent`/`RideRequestTrackingContent`'s
    // itinerary rails identically.
    private var routeCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    RideEyebrowText(text: "Pickup")
                    Text(viewerState.draftPickup?.label ?? SharedViewerState.pickupFallbackLabel)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    dismissKeyboardBeforeLeaving() // MYR-239 defect 2
                    viewerState.pinReturn = .search
                    viewerState.sheetPhase = .pinDrop(returnTo: .search)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.system(size: 11))
                        Text(viewerState.draftPickup != nil ? "On map" : "Set on map")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.mrtGold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(viewerState.draftPickup != nil ? Color.mrtGold.opacity(0.16) : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(viewerState.draftPickup != nil ? Color.mrtGold.opacity(Double(0x66) / 255.0) : Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 11)

            Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    RideEyebrowText(text: "Destination")
                    TextField("Where to?", text: $query)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                        .focused($destinationFieldFocused)
                }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Color.mrtTextMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 11)
        }
        .padding(.leading, 22) // room for the dot/line rail painted behind
        .background(alignment: .topLeading) { routeRail }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .mrtSurface(.control, fill: .mrtElevated, radius: 16)
    }

    /// The pickup (driving-green dot) → destination (gold square) connector
    /// — see this file's `routeCard` header comment for why it's a
    /// `.background` rather than an HStack sibling.
    private var routeRail: some View {
        VStack(spacing: 4) {
            Circle().fill(Color.mrtDriving).frame(width: 9, height: 9).shadow(color: .mrtDriving.opacity(0.67), radius: 4)
            Rectangle().fill(Color.mrtBorder).frame(width: 2).frame(maxHeight: .infinity)
            RoundedRectangle(cornerRadius: 2.5).fill(Color.mrtGold).frame(width: 9, height: 9).shadow(color: .mrtGoldGlow, radius: 4)
        }
        .padding(.vertical, 19)
    }

    // MARK: Region below the header (results, or the Continue CTA)

    /// Search-as-you-type results, or — once a destination is chosen (MYR-215
    /// deliverable 3) — the "Continue" CTA in their place.
    @ViewBuilder
    private var belowHeaderRegion: some View {
        if let picked = pickedDestination {
            proceedRegion(for: picked)
        } else {
            // Results list — capped to the space the header leaves inside the
            // 712pt envelope so the SHEET hugs `min(content, cap)` in sim: a full
            // list fills 712 and scrolls; a short list produces a short sheet with
            // no black void below the last row (MYR-200). Live pins it to the full
            // envelope so the frame never jumps on the first keystroke (MYR-215
            // defect 1 — see `scrollRegionHeight`).
            ScrollView {
                resultsList
                    .padding(.bottom, 16)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: SearchResultsHeightKey.self, value: geo.size.height)
                    })
            }
            .frame(height: scrollRegionHeight)
        }
    }

    /// The destination is chosen: the results list gives way to an explicit
    /// "Continue" step-CTA (MYR-215 deliverable 3). `.gold` (solid), not
    /// `.outlineDraw` — the design reserves the animated outline-draw treatment
    /// for the flow's pivotal COMMIT actions ("Request from {owner}"
    /// ride-request.jsx:451, "Confirm pickup here" :735, "Accept & send" :1406),
    /// while its plain step-advance CTAs are solid gold ("Set pickup · …" the
    /// schedule picker's confirm, :340). This proceed is a step-advance, so gold
    /// keeps outline-draw meaning the final request. "Continue" is the design
    /// system's advance verb (onboarding.jsx:398, tutorials.jsx:349).
    ///
    /// MYR-216 deliverable 1 — POST-SELECTION COLLAPSE: once a destination is
    /// chosen the sheet settles DOWN to hug its content (chips + trip card + CTA)
    /// in BOTH sim and live, one deliberate animated resize (see the body's
    /// `.animation(value: isChoosing)`). This intentionally overrides MYR-215,
    /// which — to stop the CTA from jumping the live sheet — pinned this region to
    /// the full stable typing envelope (`scrollRegionHeight`); the client
    /// re-scoped that to a deliberate collapse. Editing/clearing the field returns
    /// to the typing envelope (the results branch), so the no-per-keystroke-jump
    /// invariant while TYPING is untouched. Sim was already hugging → unchanged.
    /// Sanctioned diff: searchSelected collapses (camera/layout only, like the
    /// pin-drop zoom deviation).
    @ViewBuilder
    private func proceedRegion(for place: RidePlace) -> some View {
        let cta = MRTButton("Continue", variant: .gold) {
            dismissKeyboardBeforeLeaving() // MYR-239 defect 2 — drop focus before the phase transition
            viewerState.proceedFromSearch()
        }
        .padding(.top, 8)

        if let height = Self.proceedRegionHeight(isLive: viewerState.isLiveLocation) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                cta
            }
            .frame(height: height, alignment: .bottom)
        } else {
            cta
        }
    }

    /// MYR-216 deliverable 1 (pure, testable) — the proceed (Continue) region's
    /// fixed height, or `nil` to HUG its content. Always `nil` (both modes) so the
    /// sheet COLLAPSES onto its content on selection; the `isLive` seam is kept so
    /// the MYR-215 behavior it replaces (live pinned to the stable envelope) can be
    /// re-instated in one place if ever re-scoped. The both-modes-hug guarantee is
    /// the regression this locks in.
    static func proceedRegionHeight(isLive: Bool) -> CGFloat? { nil }

    /// Enter a chosen destination into the field WITHOUT advancing (MYR-215
    /// deliverable 3): fill the field with the resolved place name, dismiss the
    /// keyboard, and clear the results (the field is now filled). The explicit
    /// "Continue" CTA advances. Editing the field again returns to results.
    private func choose(_ place: RidePlace) {
        pickedDestination = place
        viewerState.chooseDestination(place)
        query = place.label // programmatic fill; onChange keeps the pick (label matches)
        destinationFieldFocused = false
    }

    /// MYR-239 defect 2 — FOCUS DISCIPLINE on leaving Search. The client hit a
    /// frame where the keyboard was fully up over a mid-animation sheet with NO
    /// content laid out above it (map + etched route visible behind QuickType):
    /// the destination field's first responder was still live when the phase
    /// transition (Continue → pinDrop/review, or drag-dismiss → idle) started, so
    /// the keyboard stranded as an orphan while the sheet animated out. Drop the
    /// SwiftUI focus binding AND force-resign first responder BEFORE mutating the
    /// phase, so the keyboard is committed to dismissing as the sheet transitions
    /// — never left hanging over an empty sheet. On re-entering Search the field
    /// is not re-focused (no `.focused` write sets it true), so the keyboard only
    /// ever returns when the rider taps the field, after the transition settles.
    private func dismissKeyboardBeforeLeaving() {
        destinationFieldFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    // MARK: Results

    @ViewBuilder
    private var resultsList: some View {
        if let filteredResults = searchResults {
            if filteredResults.isEmpty {
                emptyStateText("No results for \u{201C}\(query)\u{201D}")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Results").padding(.top, 6)
                    ForEach(filteredResults) { destRow($0) }
                }
            }
        } else if viewerState.isLiveLocation {
            // MYR-214: live mode must not surface the SF fixture Saved / Recent /
            // Nearby places pre-typing (same cross-country poisoning as a live
            // search would hit — a Frisco rider tapping the fixture "Home" or
            // "SFO · Terminal 2"). No real saved places until accounts (MYR-193)
            // and no session-recents store yet, so there's nothing local to list.
            //
            // MYR-215 defect 1: the search sheet now opens at its ONE stable
            // (712) height in live (see `scrollRegionHeight`) so it never jumps
            // when results arrive. This is the calm empty region that fills that
            // stable frame before the first keystroke — the existing muted
            // empty-state treatment (`emptyStateText`), no new component. As the
            // rider types, filtered Results populate in place above it.
            emptyStateText("Type a destination to search")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("Saved").padding(.top, 6)
                ForEach(RideRequestFixtures.savedPlaces) { destRow($0) }

                sectionLabel("Recent").padding(.top, 18)
                ForEach(RideRequestFixtures.recentPlaces.prefix(4)) { destRow($0) }

                sectionLabel("Nearby").padding(.top, 18).padding(.bottom, 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RideRequestFixtures.nearbyPlaces) { nearbyCard($0) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// The shared muted empty-state treatment — a centered, muted line with the
    /// list's vertical breathing room. Reused for both "No results for …" and
    /// (MYR-215) the live pre-typing calm empty region, so they read identically.
    private func emptyStateText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.mrtTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.mrtTextMuted)
    }

    private func destRow(_ place: RidePlace) -> some View {
        Button {
            choose(place)
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color.mrtGoldTileFaint)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: place.icon).font(.system(size: 15)).foregroundStyle(Color.mrtGold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                    if let subtitle = place.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.mrtTextSec)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // MYR-211: live results carry straight-line miles + 0 minutes
                // (no per-result routing). Hide each line when 0 so a live row
                // reads "X.X mi" alone rather than "0.0 mi / 0 min". Every
                // fixture row has miles>0 AND minutes>0, so sim rows are
                // unchanged (pixel-identical).
                VStack(alignment: .trailing, spacing: 1) {
                    if place.miles > 0 {
                        Text(String(format: "%.1f mi", place.miles))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.mrtText)
                    }
                    if place.minutes > 0 {
                        Text("\(place.minutes) min")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Color.mrtTextMuted)
                    }
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget)
    }

    private func nearbyCard(_ place: RidePlace) -> some View {
        Button {
            choose(place)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: place.icon).font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                Text(place.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                Text("\(String(format: "%.1f", place.miles)) mi \u{00B7} \(place.minutes) min")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextSec)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
        .mrtSurface(.control, fill: .mrtElevated, radius: 14)
    }

    // MARK: Schedule slide-up card (ride-request.jsx:296-346)

    private var scheduleSlideUpCard: some View {
        RideSlideUpCard(onDismiss: { scheduleSheetOpen = false }) {
            RideSlideUpCardTitle(title: "Schedule pickup") { scheduleSheetOpen = false }

            RideEyebrowText(text: "Day", size: 10.5).padding(.bottom, 9)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(RideRequestFixtures.scheduleDays, id: \.self) { day in
                        RideChip(title: day, selected: schedDay == day) { schedDay = day }
                    }
                }
            }
            .padding(.bottom, 18)

            RideEyebrowText(text: "Time", size: 10.5).padding(.bottom, 9)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(RideRequestFixtures.scheduleTimes, id: \.self) { time in
                        RideChip(title: time, selected: schedTime == time, monospaced: true) { schedTime = time }
                    }
                }
            }
            .padding(.bottom, 20)

            MRTButton("Set pickup \u{00B7} \(schedDay) \(schedTime)", variant: .gold) {
                viewerState.draftSchedule = RideSchedule(day: schedDay, time: schedTime)
                scheduleSheetOpen = false
            }
        }
    }
}
