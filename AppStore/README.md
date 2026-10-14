# Publishing Murmur on the Mac App Store

The app is free. Everything technical is already in the project:

| What | Where |
|---|---|
| App Sandbox | `AppStore/Murmur.entitlements` |
| Privacy manifest | `AppStore/PrivacyInfo.xcprivacy` |
| App Store build (bundle ID `com.docomoz.murmur`, signing, `.pkg`) | `build-appstore.sh` |
| Store page texts, keywords, review notes, screenshot ideas | `AppStore/metadata.md` |
| Privacy policy | `AppStore/PRIVACY.md` |
| Screenshot framing | `scripts/make_screenshot.swift` |

The App Store version is a separate app with its own bundle ID (`com.docomoz.murmur`). The DMG from GitHub stays
as it is (`app.murmur.mac`), and its settings are left alone.

---

## Step 1. Developer account (once, $99 a year)

1. The **Apple Developer** app on iPhone or Mac → Account → sign in with your Apple ID (with two-factor
   authentication) → **Enroll Now** → first and last name in Latin letters as in your ID → type **Individual** →
   pay with the card on your Apple ID.
   The app asks you to photograph your ID; the website (developer.apple.com/programs/enroll) usually skips
   that step, but Apple may ask for the document later.
2. Wait for the membership confirmation email (usually within 24 hours; if not — developer.apple.com/contact
   with your Enrollment ID).
3. App Store Connect (appstoreconnect.apple.com) → **Business** (Agreements): check that the agreement for
   free apps is accepted. Free apps don't need banking or tax forms.

## Step 2. Bundle ID (5 minutes)

developer.apple.com/account → **Certificates, Identifiers & Profiles** → **Identifiers** → **+** →
**App IDs** → **App** →
- Description: `Murmur`
- Bundle ID: **Explicit**, `com.docomoz.murmur`
- Capabilities: leave everything unchecked

→ **Continue** → **Register**.

## Step 3. Certificates (5 minutes, in Xcode)

Xcode → **Settings** → **Accounts** → **+** → Apple ID → pick your team → **Manage Certificates…** →
**+** → create two:
- **Apple Distribution** — signs the app;
- **Mac Installer Distribution** — signs the `.pkg`.

Check that they're there and copy their exact names:
```bash
security find-identity -v
```
You need strings like `Apple Distribution: Maksim Berezkin (ABCDE12345)` and
`3rd Party Mac Developer Installer: Maksim Berezkin (ABCDE12345)` (that's what the keychain calls
Mac Installer Distribution). `ABCDE12345` is your Team ID.

## Step 4. Provisioning profile (3 minutes)

Certificates, Identifiers & Profiles → **Profiles** → **+** → under Distribution pick
**Mac App Store Connect** → App ID `com.docomoz.murmur` → the Apple Distribution certificate → name
`Murmur Mac App Store` → **Generate** → **Download**. The file lands in `~/Downloads`.

## Step 5. The app record in App Store Connect (5 minutes)

App Store Connect → **Apps** → **+** → **New App**:
- Platforms: **macOS**
- Name: `Murmur: Focus & Sleep Sounds` (if it's taken, see the alternatives below)
- Primary Language: **English (U.S.)** — it's what every country without its own localization sees
- Bundle ID: `com.docomoz.murmur`
- SKU: `murmur-mac`
- User Access: Full Access

If the name is taken: `Murmur: Ambient Focus Sounds`, `Murmur: Rain & Nature Sounds`, `Murmur Ambient`.

## Step 6. Build and upload

From the project folder (use your own certificate names and Team ID):
```bash
MAS_APP_IDENTITY="Apple Distribution: Maksim Berezkin (ABCDE12345)" MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: Maksim Berezkin (ABCDE12345)" MAS_PROFILE=~/Downloads/Murmur_Mac_App_Store.provisionprofile ./build-appstore.sh
```
The result is `build/appstore/Murmur.pkg`. The script checks that the profile was issued for this bundle ID.

Upload: install the free **Transporter** app from the Mac App Store → sign in with the same Apple ID →
drag `Murmur.pkg` in → **Deliver**. The build shows up in App Store Connect in 15–30 minutes (you'll get an email).
If Apple finds a problem with the build itself, the error arrives by email.

## Step 7. Fill in the store page

App Store Connect → the app → version **1.0 Prepare for Submission**. Everything comes from `AppStore/metadata.md`:
1. **Screenshots** — at least one at 2880×1800 (how to make them is in `metadata.md`).
2. Promotional text, description, keywords, support and marketing URLs, copyright.
3. **Build** → pick the uploaded build.
4. **App Review Information**: no sign-in needed (uncheck Sign-in required), contact details,
   **Notes** — the text from `metadata.md`.
5. **Version Release**: manual or automatic after approval.
6. **App Information** on the left: categories (Productivity / Health & Fitness), age rating
   (every answer "No" → 4+), Privacy Policy URL.
7. **App Privacy** → Get Started → "No, we do not collect data" → Publish.
8. **Pricing and Availability** → Free, all countries.

Add the Russian localization in the same place (Localization → Russian): the texts are in `metadata.md`. The app's
UI switches to Russian by itself when Russian is the Mac's first language.

## Step 8. Submit for review

**Add for Review** → **Submit**. Review usually takes 1–3 days. If it's rejected, a message arrives in
App Store Connect (the App Review section); fix the issue and submit again.

---

## Updates

1. Make the changes, bump `VERSION` (for example, `1.13`) and `BUILD_NUMBER` in `build.sh` (that's `CFBundleVersion`;
   every upload needs a build number strictly greater than the previous one).
2. Run step 6 and upload with Transporter.
3. In App Store Connect: **+ Version**, What's New (English and Russian), pick the build, submit for review.

## Trying the App Store version without an account

```bash
./build-appstore.sh
```
Builds `build/appstore/Murmur.app` in the sandbox with a local signature — you can run it and check that everything
works just like the regular version. Such a build can't be uploaded. The App Store version has no self-update
(Sparkle is compiled out); `build/Murmur.app` after this script lacks it too, and no DMG is built:
run `./build.sh` again for the DMG.

## Bonus: a DMG without the Gatekeeper warning

The same account lets you ship the GitHub DMG signed with Developer ID and notarized — users no longer see
"Apple could not verify the developer". You need a **Developer ID Application** certificate (Xcode → Manage
Certificates → +) and a `notarytool` profile (once):
```bash
xcrun notarytool store-credentials murmur-notary --apple-id <your Apple ID> --team-id ABCDE12345
```
It asks for a password — not your regular one but an **app-specific password**: appleid.apple.com →
Sign-In and Security → App-Specific Passwords → create one (for example, `murmur-notary`).
Then:
```bash
DEVELOPER_ID="Developer ID Application: Maksim Berezkin (ABCDE12345)" NOTARY_PROFILE=murmur-notary ./build.sh
```
