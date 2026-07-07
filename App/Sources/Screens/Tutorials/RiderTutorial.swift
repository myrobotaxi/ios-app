import SwiftUI
import DesignSystem

// MARK: - RiderTutorial (MYR-166 — design/app/tutorials.jsx:366-375)
//
// 5-card StoryDeck walkthrough shown once, right after InviteCodeFlow joins
// the rider to a shared Tesla (RootView routes `.inviteCode`'s `onComplete`
// here — the `returning` variant from rider Settings skips it, per
// onboarding.jsx's `returning` prop, a later issue's concern).

struct RiderTutorial: View {
    let onDone: () -> Void

    var body: some View {
        StoryDeck(
            cards: [
                StoryCard(
                    title: "Request a ride in seconds.",
                    body: "Pick a destination and ask for the car — the owner gets your request instantly and can send it your way."
                ) { VigRequestRide() },
                StoryCard(
                    title: "Track every minute.",
                    body: "Follow the Tesla on the map with a live ETA, from the moment it’s on its way to the second it arrives."
                ) { VigTrack() },
                StoryCard(
                    title: "Your rides, saved.",
                    body: "Revisit past trips with routes, times, distance, and who you rode with."
                ) { VigRideHistory() },
                StoryCard(
                    title: "Cars shared with you.",
                    body: "See whose vehicles you can ride in and what each owner has allowed — all in one place."
                ) { VigSharedWith() },
                StoryCard(
                    title: "Clear boundaries.",
                    body: "As a guest you can request rides and watch the live map — never unlock or drive the car. The owner always stays in charge."
                ) { VigSafety() },
            ],
            kicker: "Welcome aboard",
            cta: "Start riding",
            onDone: onDone
        )
    }
}
