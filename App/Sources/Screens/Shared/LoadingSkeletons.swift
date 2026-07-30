import SwiftUI
import DesignSystem

// MARK: - Live-path loading skeletons (MYR-326)
//
// THE CLIENT'S REPORT (TestFlight ADYQbrr3DG, Jul 28): "Can we have skeleton
// loading or a nicer loading icon? This looks bad." — attached to owner Home
// mid cold-load: a black screen with a system `ProgressView` and "Connecting to
// your vehicles…" floating in the middle of nothing.
//
// Three surfaces in this app can be genuinely BUSY for seconds, and all three
// answered with a spinner or a bare line:
//
//   1. owner Home, cold — the fleet list (`GET /api/vehicles`) and then the
//      selected car's cold `/snapshot`. The snapshot is the slow one: MYR-319
//      retries it on a 0 / 0.8 / 3 / 9s schedule precisely because a car that is
//      asleep, offline or in service answers `503 vehicle_asleep` at first ask,
//      so this state routinely lasts ten seconds or more. That is the client's
//      screenshot.
//   2. owner Drives — the first page of drive history (and each further page).
//   3. Settings ⇢ Tesla Account — the linked-vehicle list.
//
// Each gets a skeleton shaped like the content it is waiting for, so the screen
// keeps its composition while it loads and the real data lands INTO the layout
// instead of replacing a void. Built from `MRTSkeletonBar` (DesignSystem), so
// the sweep is the app's existing `mrtShimmer` band and Reduce Motion degrades
// every one of them to static blocks (CLAUDE.md).
//
// LOADING ≠ UNAVAILABLE. Every skeleton here is reached only from a
// genuinely-in-flight branch. The honest states are untouched: "No drives yet",
// "No vehicles linked to this account", "Sign-in required to load vehicles" and
// the MYR-326 cold-read timeout all still render their own quiet copy — a
// skeleton that never resolves would be a worse lie than the spinner it
// replaces.
//
// LIVE-PATH ONLY, structurally. `SimulatedVehicleFleet.isConnecting` is `false`,
// `SimulatedDrivesFeed.isLoading`/`hasMore` are `false`, and Settings only
// consults `linkedVehicles` when the live fleet is wired — so no simulated or
// drift-gate scene can reach any branch below, and every existing capture stays
// byte-identical. The `ownerConnecting*` / `ownerDrivesLoading` /
// `ownerSettingsLoading` DEBUG scenes exist to capture them (see
// `DebugLoadingFleet`).

// MARK: - Owner Home (map + peek sheet)

/// The owner Live Map while the fleet list / cold snapshot is still in flight.
///
/// Two shapes, because two genuinely different amounts are known:
///   • the fleet list has NOT arrived — nothing is known, not even how many
///     cars there are, so the switcher chip is a placeholder too;
///   • the fleet list HAS arrived and the car's snapshot has not — the car's
///     name is known and real, so the REAL `MapHeader` renders and only the
///     sheet is a placeholder. This is the client's actual case (the list is one
///     fast REST call; the snapshot is the one that retries for ten seconds), and
///     it is why his screen was blank while the app already knew he owned Lunar.
///
/// The map itself is left as the plain background: a placeholder map would be a
/// fabricated map, and `MapBackground` is explicitly not for the real Live Map.
struct OwnerHomeLoadingSkeleton: View {
    /// The known fleet rows, or `[]` when the list hasn't loaded. Non-empty →
    /// the real switcher renders above the placeholder sheet.
    let vehicles: [Vehicle]
    @Binding var selectedIndex: Int

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()

            if vehicles.isEmpty {
                // Nothing known yet — a placeholder in the switcher chip's own
                // slot (screens.jsx:302 `top: 60`, height 40), so the chip does
                // not pop into an empty band when the list lands.
                MRTSkeletonBar(width: 132, height: MRTMetrics.mapChipHeight, radius: MRTMetrics.mapChipHeight / 2)
                    .padding(.top, MRTMetrics.mapHeaderTop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .mrtSkeletonAccessibility("Loading your vehicles")
            } else {
                MapHeader(vehicles: vehicles, selectedIndex: $selectedIndex)
            }

            OwnerHomeSheetSkeleton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The peek sheet, as a placeholder. Wears the REAL sheet chrome
/// (`.mrtSurface(.sheet)` + `MRTGrabHandle`) at the real parked peek height, so
/// the surface the owner is looking at does not move when the snapshot lands —
/// only the ink inside it appears.
///
/// Static, not an `MRTDetentSheet`: there is nothing to drag to yet, and a
/// draggable placeholder would open an empty half detent.
private struct OwnerHomeSheetSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            MRTGrabHandle()
            // The parked hero's own stack: `ParkedSummary` is
            // `VStack(alignment: .leading, spacing: 8)` of header row / battery
            // bar / location row, at `pageGutter` and `.top 6` (HomeScreen's
            // peek builder, screens.jsx:542 `padding: '6px 24px …'`). Each block
            // below stands in for one of those, at that element's own height, so
            // the real content lands in place rather than shifting the layout.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    // Vehicle name — 18pt semibold.
                    MRTSkeletonBar(width: 104, height: 18, radius: 6, emphasis: .strong)
                    // Status badge pill.
                    MRTSkeletonBar(width: 66, height: 18, radius: 9)
                    Spacer(minLength: 12)
                    // Charge figure ("64 %").
                    MRTSkeletonBar(width: 42, height: 18, radius: 6)
                }
                // `BatteryBar`'s own 6pt track.
                MRTSkeletonBar(height: 6, radius: 3)
                HStack {
                    // Parked location label — 12pt.
                    MRTSkeletonBar(width: 168, height: 12)
                    Spacer(minLength: 8)
                    // Elapsed-since-parked — 12pt, right-aligned.
                    MRTSkeletonBar(width: 34, height: 12)
                }
            }
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(height: MRTMetrics.homePeekHeightParked)
        .frame(maxWidth: .infinity)
        .mrtSurface(.sheet, fill: .mrtBgSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Full-bleed geometry (CLAUDE.md): the sheet runs flush to the PHYSICAL
        // bottom edge, exactly as `MRTDetentSheet` does.
        .ignoresSafeArea(edges: .bottom)
        .mrtSkeletonAccessibility("Connecting to your vehicle")
    }
}

// MARK: - Drives

/// One `DriveRow`-shaped placeholder. Same 15pt padding, same card radius, same
/// 11pt row gap and gutter as the real row, so a loaded page does not reflow the
/// list.
///
/// Deliberately NOT wearing the row's gold gradient/border: gold is the sacred
/// accent (CLAUDE.md "never decorative"), and a gold-tinted card with no content
/// in it reads as a real, selectable drive. The placeholder is the neutral
/// skeleton fill; the gold arrives with the data.
struct DriveRowSkeleton: View {
    /// Widths vary per row so a stack of them reads as a list of different
    /// journeys rather than a repeated graphic. Indexed, not random, so the
    /// capture scene is deterministic.
    let index: Int

    private static let routeWidths: [CGFloat] = [186, 154, 204]
    private static let statWidths: [CGFloat] = [148, 132, 158]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center) {
                    // "Ferry Building → Sunset" — 15pt semibold.
                    MRTSkeletonBar(width: Self.routeWidths[index % Self.routeWidths.count], height: 15, radius: 5, emphasis: .strong)
                    Spacer(minLength: 10)
                    // Start time — 12pt.
                    MRTSkeletonBar(width: 46, height: 12)
                }
                // "8.4 mi · 21 min · 96% FSD" — 12.5pt.
                MRTSkeletonBar(width: Self.statWidths[index % Self.statWidths.count], height: 12)
            }
            MRTSkeletonBar(width: 8, height: 14, radius: 3)
        }
        .padding(15)
        .background(Color.mrtSkeletonRowFill, in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.mrtSkeletonRowBorder, lineWidth: MRTMetrics.hairline)
        )
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 11)
    }
}

/// The first-page placeholder for owner Drives: a day heading plus three rows,
/// matching the grouped list this screen builds once the page lands.
struct DrivesListSkeleton: View {
    /// How many placeholder rows. Three fills the visible list without
    /// promising a page size the server never stated.
    static let rowCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The "Today"/"Yesterday" group heading's own slot.
            MRTSkeletonBar(width: 62, height: 11, radius: 4)
                .padding(.horizontal, MRTMetrics.pageGutter)
                .padding(.bottom, 10)
            ForEach(0..<Self.rowCount, id: \.self) { index in
                DriveRowSkeleton(index: index)
            }
        }
        .padding(.top, 4)
        .mrtSkeletonAccessibility("Loading drives")
    }
}

// MARK: - Rider Live Map (MYR-343)

/// The rider Live Map while the account's VEHICLE SET is still being resolved —
/// i.e. `GET /api/vehicles` is in flight and the shell does not yet know whether
/// this rider owns a car, holds a share, or has neither.
///
/// It exists because the shell cannot answer that question with a boolean. Before
/// MYR-343 the gate was `hasLoaded && grants.isEmpty`, so the not-yet-loaded case
/// fell through to the rider HOME and then swapped — the client's *"I briefly saw
/// the rider home page and then it prompted me to enter a code."* Any two-way
/// split has to render one of the three real situations in another's clothes for
/// a frame; this surface is the third one having its own.
///
/// Shaped like the idle greeting sheet it is waiting for, at that sheet's own
/// `sharedIdleSheetHeight` with its own gold wash, top corners, hairline and
/// shadow — so when the vehicle lands, the sheet does not move and only the ink
/// inside it appears. The map behind it is the plain background, for the same
/// reason `OwnerHomeLoadingSkeleton` leaves it plain: a placeholder map would be
/// a fabricated map.
///
/// LIVE-PATH ONLY, structurally: `SimulatedSharedVehicleCatalog.hasLoaded` is
/// `true` from the first frame, so no simulated or drift-gate scene can reach
/// this branch (the `riderVehiclesResolving` DEBUG scene exists to capture it).
struct RiderVehiclesLoadingSkeleton: View {
    /// The rider keeps their tabs while the map loads — same reasoning as
    /// `SharedNoVehiclesScreen`, and it stops the nav popping in when the vehicle
    /// lands. Live Map is the selected tab by construction (this is that tab).
    @Binding var sharedTab: String

    /// The real search bar's own height: a 16pt line (≈19pt) inside 15pt vertical
    /// padding, floored by the 44pt tap target — `SharedViewerScreen.searchBar`.
    /// Stated here rather than in `MRTMetrics` because it is a measurement OF an
    /// existing element, not a shared design token.
    private static let searchBarHeight: CGFloat = 49

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // `GreetingHero`'s own line — 21pt medium, with the 16pt gap the
                // real hero carries below it.
                MRTSkeletonBar(width: 196, height: 21, radius: 7, emphasis: .strong)
                    .padding(.bottom, 16)
                // The "Where to?" search bar: 16pt text at 15pt vertical padding
                // inside a `controlRadius` field, and the same 14pt gap under it.
                MRTSkeletonBar(height: Self.searchBarHeight, radius: MRTMetrics.controlRadius)
                    .padding(.bottom, 14)
                Spacer(minLength: 0)
            }
            // The idle sheet's own padding (SharedViewerScreen.idleSheet).
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 98)
            .frame(height: MRTMetrics.sharedIdleSheetHeight)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The SAME surface the loaded sheet wears — wash included — so the
            // only thing that changes when the vehicle lands is the ink.
            .background(RiderIdleSheetBackground())
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: MRTMetrics.sheetRadius,
                topTrailingRadius: MRTMetrics.sheetRadius,
                style: .continuous
            ))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtGoldSheetHairline).frame(height: MRTMetrics.hairline)
            }
            .shadow(color: .black.opacity(0.5), radius: 20, y: -8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .mrtSkeletonAccessibility("Loading your vehicles")
        }
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs)
    }
}

// MARK: - Settings ⇢ Tesla Account

/// A placeholder for one linked-vehicle row in the read-only live Tesla Account
/// list — the name/model line plus its plate sub-line, at the row's own 12pt
/// vertical padding and hairline separator.
struct TeslaAccountRowSkeleton: View {
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MRTSkeletonBar(width: 118, height: 14, radius: 5, emphasis: .strong)
            MRTSkeletonBar(width: 164, height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            }
        }
    }
}
