import Foundation

// MARK: - User profile (MYR-224 — real account identity)
//
// The app-facing identity value: who is signed in. Derived from the backend's
// `{ id, name?, email? }` (rest-api.md §7.10.1) via ``AuthUser`` in the Kit.
// Apple only returns a human name on the FIRST authorization, and a row created
// before native sign-in (the client's Google-era web account) may or may not
// carry one — so `name`/`email` are BOTH optional and every consumer must
// tolerate their absence (calm generic greeting, "email absent" Settings state)
// rather than render "Good morning, " + empty.
struct UserProfile: Equatable, Codable, Sendable {
    /// User CUID — always present (the access token's `sub`).
    let id: String
    /// Display name when known (first sign-in, or a previously persisted name).
    let name: String?
    /// Verified email when known.
    let email: String?

    init(id: String, name: String? = nil, email: String? = nil) {
        self.id = id
        self.name = name.flatMap(UserProfile.normalized)
        self.email = email.flatMap(UserProfile.normalized)
    }

    /// The first name for a greeting, or `nil` when no usable name exists. `nil`
    /// is the signal to fall back to a calm generic greeting ("Good morning")
    /// with no trailing name — NEVER "Good morning, ".
    var firstName: String? {
        guard let name else { return nil }
        return name.split(separator: " ").first.map(String.init)
    }

    /// A calm one-line display name for Settings when no real name is known.
    /// Prefers the real name, then the email, then a neutral generic — the
    /// profile always has an id, but a brand-new Apple sign-in that shared
    /// neither name nor email still needs something to show.
    var settingsDisplayName: String {
        name ?? email ?? "Your account"
    }

    /// The initial for an avatar tile — first letter of the display name.
    var avatarInitial: String {
        String(settingsDisplayName.prefix(1)).uppercased()
    }

    /// Trim whitespace; treat an empty string as absent (Apple can hand back an
    /// empty `PersonNameComponents` / the backend can omit the field as "").
    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
