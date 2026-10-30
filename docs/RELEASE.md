# Releasing to the App Store

BodegasNYC ships by hand from Xcode. Releases are rare, so there is no build
pipeline: this checklist is the pipeline. Work through it top to bottom.

## One-time setup (before the first submission)

Status as of 2026-10-29 is in brackets.

- [ ] **Account deletion in the app** (#127). App Review guideline 5.1.1(v)
      requires it for any app with sign-in. Submitting without it is a
      guaranteed rejection. [not built]
- [ ] **App record in App Store Connect**: bundle id `Yukichi.BodegasNYC`,
      name "Bodegas NYC", primary category Food & Drink (or Travel), age
      rating questionnaire (user-generated content: photos and reviews are
      user content, so answer "yes" to UGC and make sure the flag-an-issue flow
      and a way to contact you are in place; that is what Apple checks for
      guideline 1.2). [not created]
- [ ] **Sign in with Apple** is on for the App ID in the developer portal.
      Automatic signing adds it; confirm under Certificates, Identifiers &
      Profiles → Identifiers → BodegasNYC → Capabilities.
- [ ] **Privacy policy URL**. The policy text is `docs/PRIVACY.md`. This repo
      is private, so GitHub Pages is not available on the free plan; host it
      as a public gist or in a tiny public `bodegasnyc-site` repo with Pages
      on. Paste the URL into App Store Connect → App Privacy and into the app
      listing. [not hosted]
- [ ] **App Privacy questionnaire** in App Store Connect. Answer from
      `BodegasNYC/PrivacyInfo.xcprivacy`, which is the source of truth:
      precise location (not linked, app functionality), email address and
      user id (linked), photos and other user content (linked). No tracking.
      Change the manifest first if the answers change.
- [ ] **App Review notes** (App Store Connect → version → App Review
      Information). Paste something like:

      > Finding bodegas uses When-In-Use location only. "Streets Walked" is an
      > optional feature, off by default, started from its own menu in the app,
      > that records the streets the user walks so they can see them
      > highlighted on their own map. It is the only thing that asks for
      > Always location and the background `location` mode. The walk history
      > stays on the device (SwiftData) and is never uploaded. To try it: on
      > the map, tap the walking-figure "Streets Walked" button in the top bar
      > → Start Recording, grant Always, walk or simulate a route (Features →
      > Location → Freeway Drive on a simulator), then reopen the app.

      Also give the reviewer a sign-in path. Sign in with Apple works on
      their device, but add the test account email/password from
      `~/.config/bodegasnyc/test-account.xcconfig` to the demo account
      fields only if the Release build can accept it (it cannot: the
      email/password sign-in is `#if DEBUG`). So say "Sign in with Apple only;
      no demo account needed, all browsing works signed out."
- [ ] **Screenshots**. `TARGETED_DEVICE_FAMILY` is `1,2`, so App Store Connect
      requires iPad screenshots as well as iPhone 6.9" and 6.5" (or 6.7"). If
      the iPad layout has never been QA'd, either set the device family to
      iPhone only before the first release or do an iPad pass first. Take them
      from the Simulator (`Cmd-S`) on a build with real data, not UI-test
      fixtures.
- [ ] **Hosted Supabase is production**. The Release build reads
      `SUPABASE_URL` / `SUPABASE_ANON_KEY` from the target's build settings
      (same project as Debug: `fdzjfdvotkodwimtsiuu`). Confirm every migration
      in `supabase/migrations` has been pushed (`supabase db push --linked
      --dry-run` prints nothing pending) and that RLS is on for every table.
- [ ] **Encryption**. `ITSAppUsesNonExemptEncryption` is `NO` in `Info.plist`
      (HTTPS only, no custom crypto), so the export-compliance question is
      skipped on each upload.

## Every release

1. **Pick the version.** `MARKETING_VERSION` is what users see (1.0, 1.1,
   1.1.1). `CURRENT_PROJECT_VERSION` (the build number) must go up on every
   upload, even for the same marketing version. Set both in Xcode → target
   BodegasNYC → General → Identity. They are set per configuration in
   `project.pbxproj`; Xcode edits all of them together.
2. **Main is green.** `git checkout main && git pull`, no open PRs you want in
   this release, then:
   ```sh
   scripts/run-tests.sh --ui      # run_in_background; waits for a build slot
   ```
3. **Release build compiles** (catches `#if DEBUG` leaks and missing symbols
   that Debug builds hide):
   ```sh
   xcodebuild -project BodegasNYC.xcodeproj -scheme BodegasNYC \
     -configuration Release -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath build/dd -skipPackagePluginValidation \
     CODE_SIGNING_ALLOWED=NO build
   ```
   Then confirm the built `Info.plist` has `SUPABASE_URL` set and
   `TEST_ACCOUNT_EMAIL` empty:
   ```sh
   plutil -p build/dd/Build/Products/Release-iphonesimulator/BodegasNYC.app/Info.plist \
     | grep -E 'SUPABASE_URL|TEST_ACCOUNT|CFBundleShortVersionString|CFBundleVersion'
   ```
4. **Smoke test on a device**, Release scheme: Xcode → Product → Scheme →
   Edit Scheme → Run → Build Configuration → Release, run on your iPhone,
   sign in with Apple, open a bodega, add a photo, start and stop a walk.
   Switch the scheme back to Debug afterwards.
5. **Archive**: Xcode → select "Any iOS Device (arm64)" → Product → Archive.
   Organizer opens when it finishes.
6. **Upload**: Organizer → Distribute App → App Store Connect → Upload.
   Keep "Upload your app's symbols" on. Automatic signing handles the
   distribution certificate and profile.
7. **Tag the commit** you archived from, so the build maps back to source:
   ```sh
   git tag -a v1.0-1 -m "App Store build 1 of 1.0" && git push origin v1.0-1
   ```
   Format: `v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`.
8. **App Store Connect**: wait for processing (a few minutes to an hour),
   attach the build to the version, fill in "What's New", check the App
   Review notes still describe the build, then Submit for Review.
9. **TestFlight first** if the change touched location, sign-in or photo
   upload: install the processed build via TestFlight on your own phone
   before submitting. It is the same binary App Review will see.

## After approval

- Release manually from App Store Connect, or set "Automatically release"
  when submitting.
- Note anything the reviewer asked for in this file so the next release
  does not re-learn it.

## When dependencies change

`BodegasNYC/PrivacyInfo.xcprivacy` declares the required-reason APIs the app
uses (`UserDefaults`, reason CA92.1). After bumping a Swift package, check it
still uses none of the listed APIs, or add the reasons:

```sh
grep -rnE 'UserDefaults|systemUptime|mach_absolute_time|modificationDate|creationDate|volumeAvailableCapacity|activeInputModes' \
  build/dd/SourcePackages/checkouts/<package>/Sources
```

Packages that ship their own `PrivacyInfo.xcprivacy` (swift-crypto does) are
covered by Xcode when it aggregates the manifests at archive time.
