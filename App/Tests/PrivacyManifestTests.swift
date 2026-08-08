import Foundation
import XCTest

// MARK: - MYR-434 — the privacy manifest, pinned against the code that collects
//
// `PrivacyInfo.xcprivacy` shipped with an EMPTY `NSPrivacyCollectedDataTypes`
// while the app transmitted name, email, a precise pickup coordinate, two push
// tokens and a pile of owner-typed text. Nothing caught it for the same reason
// nothing catches a stale comment: the manifest is a RESOURCE. It is not
// compiled, not imported and not referenced by a single Swift symbol, so adding
// a collecting code path can never fail a build or a test — the declaration can
// only drift, and drifting is exactly what it did.
//
// This suite is the missing edge. It reads the manifests OUT OF THE BUILT
// BUNDLES rather than off disk, which is what makes it a wiring test as well as
// a content test: `App/Sources/PrivacyInfo.xcprivacy` is picked up purely
// because of where the file sits (there is no `project.yml` entry for it), so a
// reorganisation that moves it somewhere XcodeGen does not sweep would ship an
// app with NO manifest at all and every string in the repo still correct.
// `Bundle.main` is the HOST APP for a hosted unit test — `SettingsFooterParityTests`
// already relies on that to read `CFBundleShortVersionString`.
//
// The expected sets are spelled out here as literals ON PURPOSE. A test that
// derived them from the file it is checking would pass for any file, which is
// the tautology `testTheCaptionNeverCoversItsOwnSubject` shipped in MYR-428:
// the declaration and the expectation have to be two independent statements or
// the comparison is `x == x`. So changing what the app collects means editing
// TWO places, and the second one is a diff a reviewer reads as a privacy claim
// rather than as a plist blob.
//
// What each declared type is derived from is documented at length in the
// manifest's own comment; the justification table lives there, next to the
// declaration, rather than being duplicated into assertions here.
final class PrivacyManifestTests: XCTestCase {

    // MARK: - The two declarations, stated independently of the files

    /// Every data type the APP is allowed to declare. Derived call-site by
    /// call-site in MYR-434 — see the manifest comment for which wire field
    /// produces each one.
    private static let expectedAppCollectedTypes: Set<String> = [
        "NSPrivacyCollectedDataTypeName",
        "NSPrivacyCollectedDataTypeEmailAddress",
        "NSPrivacyCollectedDataTypePreciseLocation",
        "NSPrivacyCollectedDataTypeUserID",
        "NSPrivacyCollectedDataTypeDeviceID",
        "NSPrivacyCollectedDataTypeOtherUserContent",
        "NSPrivacyCollectedDataTypeOtherDataTypes",
    ]

    /// `UserDefaults` is the only required-reason category this app calls, and
    /// CA92.1 ("access info from the same app") is the only reason it needs.
    private static let expectedAccessedAPIs: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
    ]

    // MARK: - The app's manifest

    /// **The whole of MYR-434 as one assertion.** The set is compared WHOLE, in
    /// both directions, so an addition fails as loudly as a removal — a new
    /// collecting code path whose type nobody declared is the defect this issue
    /// fixed, and a declaration nobody can point at a call site for is the
    /// over-claim on the other side of it.
    func testTheAppDeclaresExactlyTheDataTypesItActuallyCollects() throws {
        let manifest = try appManifest()
        let declared = try collectedTypeIdentifiers(in: manifest)

        XCTAssertEqual(declared, Self.expectedAppCollectedTypes)
        XCTAssertFalse(declared.isEmpty,
                       "an empty NSPrivacyCollectedDataTypes is the MYR-434 defect itself")
    }

    /// Every declared type is `Linked` and NOT `Tracking`, and this is
    /// structural rather than a policy anyone has to remember. Linked: there is
    /// no anonymous mode — every REST call carries the account's bearer token,
    /// so nothing reaches the server detached from an identity. Tracking: the
    /// app has no third-party dependencies at all, so there is no SDK that
    /// could be doing it. If either of these ever stops being true, the type
    /// that changed needs its own reasoning and this sweep is where that
    /// argument has to be made.
    func testEveryDeclaredTypeIsLinkedToIdentityAndNoneIsUsedForTracking() throws {
        let manifest = try appManifest()
        let entries = try collectedDataTypes(in: manifest)

        for entry in entries {
            let identifier = entry["NSPrivacyCollectedDataType"] as? String ?? "<unnamed>"
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true,
                           "\(identifier) must be linked — the app has no anonymous mode")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false,
                           "\(identifier) must not be tracking — there are no third-party SDKs")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
                           "\(identifier) exists to make the product work and for nothing else")
        }
    }

    /// **MYR-382's removal, defended from the manifest side.** The passenger
    /// name/phone UI is gone and `SharedViewerState.draftPassenger` has no
    /// writer outside `App/Tests`, so on a shipping build the optional wire
    /// fields are always nil and their keys never encode — a user cannot enter
    /// a phone number anywhere in the app. `/privacy` says the same thing in
    /// prose ("there is no way to book on someone else's behalf"). Declaring a
    /// contact-info type would therefore claim a collection that does not
    /// happen, which is its own kind of false statement. If anyone re-adds a
    /// writer to `draftPassenger`, THIS is the assertion that has to be
    /// deleted first, deliberately, by someone who has read why it is here.
    func testTheRetiredPassengerFieldsAreNotDeclaredAsACollection() throws {
        let manifest = try appManifest()
        let declared = try collectedTypeIdentifiers(in: manifest)

        XCTAssertFalse(declared.contains("NSPrivacyCollectedDataTypePhoneNumber"),
                       "MYR-382 removed the passenger phone field — no phone number is collectable")
        XCTAssertFalse(declared.contains("NSPrivacyCollectedDataTypeOtherUserContactInfo"),
                       "a third party's contact details cannot be entered anywhere in the app")
    }

    /// The app has no analytics, no advertising identifier and no cross-app
    /// tracking, so the tracking flag is false and the domain list is empty.
    /// An empty `NSPrivacyTrackingDomains` under `NSPrivacyTracking = true`
    /// would be incoherent, and a domain listed under `false` would be dead
    /// weight a reviewer has to interpret.
    func testTheAppDeclaresNoTrackingAndNoTrackingDomains() throws {
        let manifest = try appManifest()

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [],
                       "no domain may be listed while the app declares it does not track")
    }

    /// `UserDefaults` / CA92.1 and nothing else. The call sites are far broader
    /// than the three the pre-MYR-434 comment named, but the CATEGORY is still
    /// the only one in use — the app touches no file-timestamp, system-boot,
    /// disk-space or active-keyboard API anywhere (`FileManager` appears in no
    /// Swift file in the repo). Adding a call to any of those without declaring
    /// it is an App Store rejection, so the absence is asserted rather than
    /// assumed.
    func testTheRequiredReasonAPIDeclarationMatchesWhatTheAppCalls() throws {
        let manifest = try appManifest()
        XCTAssertEqual(try accessedAPIReasons(in: manifest), Self.expectedAccessedAPIs)
    }

    // MARK: - The widget extension's manifest

    /// **The wiring half, and the reason this reads the BUILT bundle.** A
    /// privacy manifest is bundle-scoped: the app's copy does not describe the
    /// `.appex`, which before MYR-434 had no Resources build phase and shipped
    /// no manifest at all. Nothing in `project.yml` mentions either file — both
    /// are swept in by their position under a target's `sources:` root — so
    /// this assertion is what notices if that sweep ever stops happening.
    func testTheWidgetExtensionShipsItsOwnManifestAtItsBundleRoot() throws {
        XCTAssertNoThrow(try widgetManifest(),
                         "the .appex is a separate bundle and needs its own manifest")
    }

    /// The extension's declaration is empty because the extension does neither
    /// thing, and BOTH halves were checked rather than assumed. It cannot
    /// transmit: `project.yml` links it to DesignSystem and contracts only and
    /// to MyRoboTaxiKit not at all, so there is no REST client in that process
    /// — its content arrives at `Activity.request` and over APNs, and rendering
    /// data is not collecting it. And it calls no required-reason API: zero
    /// `UserDefaults` across `Widgets/Sources`, `App/ActivityShared` and
    /// DesignSystem, with no App Group to reach the app's defaults through.
    ///
    /// This is the one place in the repo where an empty declaration is the
    /// correct answer, which is exactly why it is asserted — it turns "this
    /// bundle declares nothing" from an unaudited ABSENCE into a claim that is
    /// re-checked on every run. The day this extension gains a network client
    /// or an App Group, this test fails and the manifest has to catch up.
    func testTheWidgetExtensionDeclaresNothingBecauseItCollectsAndAccessesNothing() throws {
        let manifest = try widgetManifest()

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertEqual(try collectedTypeIdentifiers(in: manifest), [],
                       "the extension has no network client and cannot transmit anything")
        XCTAssertEqual(try accessedAPIReasons(in: manifest), [:],
                       "the extension's whole compiled surface calls no required-reason API")
    }

    // MARK: - Reading the manifests out of the built bundles

    /// The app's manifest, read from the app bundle ROOT — where Apple looks,
    /// and where XcodeGen puts a `.xcprivacy` found under `App/Sources`.
    private func appManifest() throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
            throw ManifestProblem.missing("MyRoboTaxi.app/PrivacyInfo.xcprivacy")
        }
        return try parse(at: url)
    }

    /// The extension's manifest, read from inside the EMBEDDED `.appex`. Going
    /// through `builtInPlugInsURL` rather than the source tree is the point:
    /// it proves the file was copied into the extension's own bundle, which is
    /// the fact a source-file check cannot establish.
    private func widgetManifest() throws -> [String: Any] {
        guard let plugIns = Bundle.main.builtInPlugInsURL else {
            throw ManifestProblem.missing("MyRoboTaxi.app/PlugIns")
        }
        let url = plugIns
            .appendingPathComponent("MyRoboTaxiWidgets.appex")
            .appendingPathComponent("PrivacyInfo.xcprivacy")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ManifestProblem.missing("MyRoboTaxiWidgets.appex/PrivacyInfo.xcprivacy")
        }
        return try parse(at: url)
    }

    private func parse(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw ManifestProblem.malformed(url.lastPathComponent)
        }
        return dictionary
    }

    /// A MISSING key and an EMPTY array are deliberately not the same thing
    /// here. Apple treats an absent `NSPrivacyCollectedDataTypes` as "nothing
    /// declared", which is what the app's manifest said for two releases — so
    /// a manifest that simply dropped the key would otherwise pass the
    /// widget's emptiness assertion while failing to state anything at all.
    private func collectedDataTypes(in manifest: [String: Any]) throws -> [[String: Any]] {
        guard let entries = manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] else {
            throw ManifestProblem.malformed("NSPrivacyCollectedDataTypes")
        }
        return entries
    }

    private func collectedTypeIdentifiers(in manifest: [String: Any]) throws -> Set<String> {
        Set(try collectedDataTypes(in: manifest).compactMap { $0["NSPrivacyCollectedDataType"] as? String })
    }

    private func accessedAPIReasons(in manifest: [String: Any]) throws -> [String: Set<String>] {
        guard let entries = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
            throw ManifestProblem.malformed("NSPrivacyAccessedAPITypes")
        }
        return entries.reduce(into: [:]) { table, entry in
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String else { return }
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            table[category, default: []].formUnion(reasons)
        }
    }

    private enum ManifestProblem: Error, CustomStringConvertible {
        case missing(String)
        case malformed(String)

        var description: String {
            switch self {
            case .missing(let what): return "no privacy manifest at \(what)"
            case .malformed(let what): return "\(what) is not the shape a privacy manifest requires"
            }
        }
    }
}
