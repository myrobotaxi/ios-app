import SwiftUI
import UIKit

// MARK: - ActivityShareSheet (MYR-169 Drive Summary)
//
// Thin `UIViewControllerRepresentable` wrapper around `UIActivityViewController`
// — Handoff §5.6 calls for "FSD share via `UIActivityViewController`" rather
// than SwiftUI's `ShareLink`, since the drive summary shares a composed image
// (the rendered `DriveShareCard`) alongside plain text, and `ShareLink` only
// accepts a single homogeneous `Transferable` item. Present with
// `.sheet(isPresented:)`.
public struct ActivityShareSheet: UIViewControllerRepresentable {
    private let activityItems: [Any]
    private let excludedActivityTypes: [UIActivity.ActivityType]?

    public init(activityItems: [Any], excludedActivityTypes: [UIActivity.ActivityType]? = nil) {
        self.activityItems = activityItems
        self.excludedActivityTypes = excludedActivityTypes
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
