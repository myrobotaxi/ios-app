# Releasing MyRoboTaxi to TestFlight

The full archive → export → upload pipeline for the MyRoboTaxi iOS app, plus
the App Store Connect steps that only the account holder (Thomas) can do.

- **App:** MyRoboTaxi (SwiftUI)
- **Bundle id:** `app.myrobotaxi.ios`
- **Team:** `NFKX777598`
- **Signing:** Automatic (managed distribution profile carries the Sign In with Apple entitlement)
- **Project:** generated from `project.yml` via XcodeGen — the `.xcodeproj` is **not** committed

Requires full Xcode (not just Command Line Tools). Verified against Xcode 26.6.

---

## 0. One-time prerequisites

- Xcode signed in to the Apple ID that belongs to team `NFKX777598`
  (Xcode ▸ Settings ▸ Accounts), OR the App Store Connect API key below.
- `brew install xcodegen`
- The app record must already exist in App Store Connect (see
  **Thomas's manual checklist** at the bottom) — the first `altool` upload
  fails if no app with bundle id `app.myrobotaxi.ios` exists yet.

---

## 1. Versioning

Set in `project.yml` under the `MyRoboTaxi` target:

- `MARKETING_VERSION` — public version (`CFBundleShortVersionString`), currently **1.0.0**.
- `CURRENT_PROJECT_VERSION` — build number (`CFBundleVersion`), committed baseline **1**.

The build number **must be unique and monotonically increasing** for every
upload to App Store Connect — a version bump is not required, but a fresh build
number is. Override it at archive time instead of editing the committed value:

```sh
export BUILD_NUMBER=$(date +%Y%m%d%H%M)   # or a CI build counter
```

Pass `CURRENT_PROJECT_VERSION=$BUILD_NUMBER` to the archive command in step 3.

---

## 2. Generate the project

```sh
cd /path/to/ios-app
xcodegen generate
```

---

## 3. Archive (Release, automatic signing)

```sh
xcodebuild \
  -project MyRoboTaxi.xcodeproj \
  -scheme MyRoboTaxi \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/MyRoboTaxi.xcarchive \
  DEVELOPMENT_TEAM=NFKX777598 \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION=$BUILD_NUMBER \
  -allowProvisioningUpdates \
  archive
```

`-allowProvisioningUpdates` lets Xcode create/refresh the managed distribution
profile the first time. Release strips every `#if DEBUG` scene (DebugScenes,
showcases) automatically.

---

## 4. Export the .ipa

Uses the committed `ExportOptions.plist` (`method: app-store-connect`,
automatic signing, team `NFKX777598`):

```sh
xcodebuild -exportArchive \
  -archivePath build/MyRoboTaxi.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates
```

Produces `build/export/MyRoboTaxi.ipa`.

---

## 5. Upload to App Store Connect / TestFlight

Authenticate with an **App Store Connect API key** (created by Thomas — see the
checklist). Point the tools at the key with these environment variables:

```sh
export ASC_KEY_ID=XXXXXXXXXX                       # the key's Key ID
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   # Issuer ID (top of the Keys page)
# altool discovers the key file automatically if it is placed at one of:
#   ./private_keys/AuthKey_$ASC_KEY_ID.p8
#   ~/private_keys/AuthKey_$ASC_KEY_ID.p8
#   ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
```

The `.p8` is a secret — it is git-ignored (`*.p8`) and must never be committed.

Validate first, then upload:

```sh
xcrun altool --validate-app \
  -f build/export/MyRoboTaxi.ipa \
  --type ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

xcrun altool --upload-app \
  -f build/export/MyRoboTaxi.ipa \
  --type ios \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"
```

`altool` reads the `.p8` from the standard `private_keys` search paths above
(it does not take an explicit path flag; if it can't find the key, copy it to
`~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8`).

After upload, the build appears in App Store Connect ▸ TestFlight in a few
minutes (initial "Processing"), then is assignable to testers.

### Alternative: notarytool-style upload via xcodebuild

You can skip steps 4–5 and upload straight from the archive:

```sh
xcodebuild -exportArchive \
  -archivePath build/MyRoboTaxi.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_KEY_PATH"
```

with `destination` set to `upload` in `ExportOptions.plist` — but the explicit
`altool --validate-app` → `--upload-app` flow above gives clearer errors.

---

## 6. Export compliance

`Info.plist` already declares `ITSAppUsesNonExemptEncryption = false` (the app
uses only standard HTTPS/TLS). TestFlight therefore does **not** prompt for
export compliance on each build.

---

# Thomas's manual checklist (App Store Connect — account-holder only)

These steps require signing in to <https://appstoreconnect.apple.com> and
cannot be scripted from this repo. Do them once before the first upload.

### A. Create the app record

1. App Store Connect ▸ **Apps** ▸ **+** ▸ **New App**.
2. Platform: **iOS**.
3. **Name:** `MyRoboTaxi` (the public App Store name; must be globally unique —
   have a fallback like `MyRoboTaxi App` ready if taken).
4. **Primary language:** English (U.S.).
5. **Bundle ID:** select `app.myrobotaxi.ios`. If it's not in the list, first
   register it at Apple Developer ▸ Certificates, IDs & Profiles ▸ Identifiers
   (team `NFKX777598`), with the **Sign In with Apple** capability enabled.
6. **SKU:** any stable internal string, e.g. `MYROBOTAXI-IOS-001`.
7. **User Access:** Full Access. Create.

### B. Create an App Store Connect API key

1. App Store Connect ▸ **Users and Access** ▸ **Integrations** tab ▸
   **App Store Connect API** ▸ **Team Keys**.
2. **Generate API Key** (**+**). Name it e.g. `MyRoboTaxi CI Upload`.
3. **Access role:** **App Manager** (sufficient to upload builds and manage
   TestFlight).
4. Generate, then **Download** the `.p8` — it downloads **once only**.
5. Note the **Key ID** (on the key row) and the **Issuer ID** (at the top of
   the Keys page).
6. Put the key locally where `altool` finds it and keep it secret:
   ```sh
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
   chmod 600 ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
   ```
   Then export `ASC_KEY_ID`, `ASC_ISSUER_ID` (and optionally `ASC_KEY_PATH`) as
   in step 5. **Never commit the `.p8`** — it is git-ignored.

### C. Add internal testers (available as soon as the build finishes processing)

1. TestFlight ▸ **Internal Testing** ▸ create/​select an internal group.
2. Add testers by Apple ID — internal testers must be **Users** on the team
   (Users and Access). Up to 100, no beta review required.
3. Enable the processed build for the group; testers get the invite in
   TestFlight.

### D. External testers + beta review (later, before wider distribution)

1. TestFlight ▸ **External Testing** ▸ create a group ▸ add testers or a public
   link.
2. Fill in **Test Information**: what to test, beta description, feedback email,
   marketing/privacy URLs.
3. **Beta App Review** notes: a demo Apple account or Sign In with Apple test
   path, plus notes on the owner/rider roles. The first external build must
   pass Beta App Review before external testers can install.
4. Complete the **Export Compliance** and **Content Rights** questions if
   prompted (encryption is already declared exempt in the build).
