import SwiftUI
import DesignSystem

// MARK: - OwnerTutorial (MYR-166 — design/app/tutorials.jsx:355-364)
//
// 5-card StoryDeck walkthrough shown once, right after AddTeslaFlow pairs
// the owner's Tesla (RootView routes `.addTesla`'s `onComplete` here).

struct OwnerTutorial: View {
    let onDone: () -> Void

    var body: some View {
        StoryDeck(
            cards: [
                StoryCard(
                    title: "Your car, live.",
                    body: "Watch your Tesla move in real time — location, speed, battery, and status, always a glance away."
                ) { VigLiveMap() },
                StoryCard(
                    title: "Every drive, remembered.",
                    body: "Trips log automatically with routes, distance, duration, and energy used. Tap any drive for the full summary."
                ) { VigDrives() },
                StoryCard(
                    title: "Share with people you trust.",
                    body: "Invite family and friends to watch the live map or request rides — you control exactly what each person can see and do."
                ) { VigSharing() },
                StoryCard(
                    title: "Send the car to anyone.",
                    body: "Get a ride request, glance at the destination and battery, and dispatch your Tesla with a single tap."
                ) { VigRequest() },
                StoryCard(
                    title: "Comfort, before you’re in.",
                    body: "Pre-condition the cabin, lock or unlock, and control media — all from your phone, wherever you are."
                ) { VigClimate() },
            ],
            kicker: "Getting started",
            cta: "Go to my car",
            onDone: onDone
        )
    }
}
