import Foundation

// MARK: - TeslaRelinkRoute (MYR-301)
//
// A command notice that says "Reconnect Tesla …" is only honest if the owner can
// actually get to the reconnect from where they read it. The app already HAS the
// link flow — Settings → Tesla Account → "Add another Tesla" → `AddTeslaFlow` →
// `ASWebAuthenticationSession` (MYR-246) — and re-running it is exactly what
// re-consents and picks up a missing scope such as `vehicle_charging_cmds`.
// So this routes to that flow rather than building a second web flow.
//
// It is a value type (not a router the views can see) for the same reason
// `OwnerDrivesState.openDriveID` exists: screens never see the router — they
// report an intent, `RootView` owns the navigation. Making it a type rather than
// an inline closure keeps the two-step "switch tab AND arm the flow" in ONE
// testable place; arming without switching tabs, or switching without arming,
// both silently do nothing.
@MainActor
struct TeslaRelinkRoute {
    /// The owner nav tab that hosts the Tesla Account section
    /// (`MRTTab.ownerTabs`, DesignSystem/Primitives/BottomNav.swift).
    static let settingsTab = "settings"

    /// Selects an owner nav tab (`RootView.ownerTab`).
    var selectTab: (String) -> Void
    /// Arms the Tesla link flow so Settings opens `AddTeslaFlow` on arrival
    /// instead of making the owner find "Add another Tesla" themselves.
    var startLink: () -> Void

    /// Take the owner to the fix.
    func callAsFunction() {
        selectTab(Self.settingsTab)
        startLink()
    }
}
