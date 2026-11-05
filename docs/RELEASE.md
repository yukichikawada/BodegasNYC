# Releasing to the App Store

BodegasNYC ships by hand from Xcode. Releases are rare, so there is no build
pipeline: this checklist is the pipeline. Work through it top to bottom.

## One-time setup (before the first submission)

Status as of 2026-11-03 is in brackets.

- [x] **Account deletion in the app** (#127). App Review guideline 5.1.1(v)
      requires it for any app with sign-in. Built in #127: Account menu →
      Your Account… → Delete Account, backed by the `delete-account` edge
      function. The server side needs the steps below before it works.
- [x] **Account deletion, server side** (#127; done 2026-10-31: migration pushed,
      `APPLE_*` secrets set, `delete-account` deployed; only step 5, the device
      test, remains and is part of #139. Kept for the next key rotation; in this order;
      the migration must go first, or the first deletion cascades the
      user's bodegas away):
      1. `supabase db push --linked --yes` (applies
         `20261030140000_bodegas_created_by_set_null.sql`; one-way once a
         bodega has lost its owner).
      2. Developer portal → Keys → new key with Sign in with Apple enabled.
         Download the `.p8` once, note the Key ID, and keep the file outside
         the repo (`~/.config/bodegasnyc/AuthKey_<id>.p8`).
      3. `supabase secrets set APPLE_CLIENT_ID=Yukichi.BodegasNYC
         APPLE_TEAM_ID=3BAMVTHBKF APPLE_KEY_ID=<id>
         APPLE_PRIVATE_KEY="$(cat ~/.config/bodegasnyc/AuthKey_<id>.p8)"`
      4. `supabase functions deploy delete-account` (`supabase functions
         list` shows it; `supabase secrets list` shows the four `APPLE_*`
         names).
      5. Device test of the Apple path (TestFlight or a dev build against
         the hosted project): delete a throwaway Apple account, then check
         Settings → Apple Account → Sign in with Apple no longer lists My
         Bodegas. Part of #139.
- [x] **Sentry and PostHog projects** (#147; all four steps done by 2026-11-02,
      `POSTHOG_PERSONAL_API_KEY` and `POSTHOG_PROJECT_ID` are set on the linked
      project). `SENTRY_DSN` and
      `POSTHOG_API_KEY` are committed (Sentry org `heerheer`; both are public
      client keys). An empty key would skip that vendor with a log line.
      1. [DSN committed] Sentry: sign up at sentry.io (US region), create an org and a
         project with platform "Apple iOS" (`my-bodegas-ios`), copy the DSN.
         Create an organization token (Settings → Organization Tokens; its
         fixed `org:ci` scope covers debug-file upload and release creation),
         save it to `~/.config/bodegasnyc/sentry-token` (`chmod 600`), and
         `brew install getsentry/tools/sentry-cli`.
      2. [token committed] PostHog: sign up at us.posthog.com, create a project "My Bodegas",
         copy the project API key (starts with `phc_`). Leave session replay
         and autocapture off in the project settings; the SDK has them off
         too.
      3. [done] Put the DSN and key into the `SENTRY_DSN` and `POSTHOG_API_KEY`
         build settings (Debug and Release, target BodegasNYC) and commit.
         `POSTHOG_HOST` is already `https://us.i.posthog.com`.
      4. PostHog → Settings → Personal API keys: create a key scoped to
         `person:read` and `person:write` for the My Bodegas project, and note
         the project id from the project settings URL. Then `supabase secrets
         set POSTHOG_PERSONAL_API_KEY=… POSTHOG_PROJECT_ID=…` on the linked
         project and redeploy `delete-account`. Until set, the function logs
         "analytics cleanup skipped" and the runbook below covers deletions
         by hand.
- [ ] **App record in App Store Connect** (#137): bundle id `Yukichi.BodegasNYC`,
      name "My Bodegas". Every field, with the text to paste, is in
      `docs/APP_STORE.md`: record, App Information, age rating (expect 13+ for
      user-generated content), pricing, App Privacy, the 1.0 page, review
      notes. [not created; a US store search on 2026-11-03 found no "My
      Bodegas"]
- [ ] **Sign in with Apple** is on for the App ID in the developer portal.
      Automatic signing adds it; confirm under Certificates, Identifiers &
      Profiles → Identifiers → BodegasNYC → Capabilities.
- [x] **Privacy policy URL**: <https://yukichikawada.github.io/BodegasNYC/privacy/>,
      served by GitHub Pages from `docs/` on `main` (the repo is public;
      `docs/_config.yml` excludes the planning docs). The text is
      `docs/PRIVACY.md`; edit it there and the page updates on merge. Paste
      the URL into App Store Connect → App Information → Privacy Policy URL.
      Guideline 5.1.1(i) also wants the link reachable inside the app: the
      Account menu and the Account sheet both carry it (#127).
- [ ] **App Privacy questionnaire** in App Store Connect (row-by-row table in
      `docs/APP_STORE.md` section 5). Answer from
      `BodegasNYC/PrivacyInfo.xcprivacy`, which is the source of truth:
      precise location (not linked, app functionality), email address and
      user id (linked), photos and other user content (linked), and for
      Share Usage and Diagnostics (#147): crash data, performance data and
      other diagnostic data (linked = yes, tracking = no, app
      functionality), product interaction and other usage data (linked =
      yes, tracking = no, analytics). Linked because a signed-in user's
      reports carry their user id. No tracking. Change the manifest first if
      the answers change.
- [ ] **App Review notes** (App Store Connect → version → App Review
      Information). The final text is in `docs/APP_STORE.md` section 6; the
      location paragraph reads:

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
- [ ] **Screenshots** (#138). The app is iPhone only (`TARGETED_DEVICE_FAMILY = 1`),
      so App Store Connect needs one iPhone set: upload 6.9" (1320 × 2868) and
      it scales down to the other sizes; add 6.5" only if the scaled frames look
      wrong. Taken 2026-11-03 on the shipped map look (dark and light, dark
      recommended); owner sign-off and the framed marketing versions pending.
      Order and filenames are in `docs/APP_STORE.md` section 6. Adding iPad
      back means an iPad layout pass first.
- [x] **Hosted Supabase is production** (checked 2026-11-03: no pending
      migrations, `delete-account` v3 deployed, `APPLE_*` and `POSTHOG_*` secrets
      set; re-run the checks before the archive). The Release build reads
      `SUPABASE_URL` / `SUPABASE_ANON_KEY` from the target's build settings
      (same project as Debug: `fdzjfdvotkodwimtsiuu`). Confirm every migration
      in `supabase/migrations` has been pushed (`supabase db push --linked
      --dry-run` prints nothing pending), that RLS is on for every table, and
      that every function in `supabase/functions` is deployed (`supabase
      functions list`) with its secrets set (`supabase secrets list`).
- [x] **Encryption**. `ITSAppUsesNonExemptEncryption` is `NO` in `Info.plist`
      (HTTPS only, no custom crypto), so the export-compliance question is
      skipped on each upload.
- [x] **App icon** (#136; done 2026-11-04). `BodegasNYC/AppIcon.icon` is the
      Icon Composer document (the West Village map with the walked trail and
      the pin; three groups, Liquid Glass on the pin and the breadcrumbs), picked
      up automatically by the synchronized `BodegasNYC` folder. The
      `AppIcon.appiconset` PNGs of the same name are the system's own flattened
      renders of it (light, dark, mono) and act as the fallback. The candidates,
      the generator scripts and the OpenStreetMap extract live under
      `~/.gstack/projects/yukichikawada-BodegasNYC/app-icon/`; open the `.icon`
      in Icon Composer (Xcode 27.2's copy) to change it, then regenerate the
      three PNGs with `tools/carx.swift` from an `actool` compile.

## Every release

1. **Pick the version.** `MARKETING_VERSION` is what users see and follows
   semantic versioning, always three parts (1.0.0, then 1.0.1 for a fix-only
   release, 1.1.0 for new features, 2.0.0 for a break in what people expect;
   decided 2026-11-04). `CURRENT_PROJECT_VERSION` (the build number) is a
   plain integer that must go up on every upload, even for the same
   marketing version, and never resets. Set both in Xcode → target
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
   Then confirm the built `Info.plist` has `SUPABASE_URL`, `SENTRY_DSN`,
   `POSTHOG_API_KEY` and `POSTHOG_HOST` set and `TEST_ACCOUNT_EMAIL` empty
   (an empty `SENTRY_DSN` or `POSTHOG_API_KEY` ships a build that sends no
   crash or usage reports):
   ```sh
   plutil -p build/dd/Build/Products/Release-iphonesimulator/BodegasNYC.app/Info.plist \
     | grep -E 'SUPABASE_URL|SENTRY_DSN|POSTHOG|TEST_ACCOUNT|CFBundleShortVersionString|CFBundleVersion'
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
6c. **Command-line alternative to 5 and 6** (used for builds 1 to 3 of 1.0 on
   2026-11-03/04; no Xcode UI, works while another session uses Xcode). The
   App Store Connect app record must exist first or the upload is refused.
   Archive 1.0 with Xcode 26.6 (the toolchain every 1.0 device check used),
   even though tests now run under Xcode 27.2 (see CLAUDE.md): set
   `DEVELOPER_DIR` explicitly so the choice does not depend on `xcode-select`.
   Move archives to 27.2 after a device pass on an iOS 27 SDK build.
   ```sh
   export DEVELOPER_DIR=/Applications/Xcode26_6.app/Contents/Developer
   until [ "$(pgrep -x xcodebuild | wc -l)" -lt 2 ]; do sleep 30; done
   xcodebuild archive -project BodegasNYC.xcodeproj -scheme BodegasNYC \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath build/archives/MyBodegas-<ver>-<build>.xcarchive \
     -derivedDataPath build/dd-archive -skipPackagePluginValidation \
     -allowProvisioningUpdates
   xcodebuild -exportArchive \
     -archivePath build/archives/MyBodegas-<ver>-<build>.xcarchive \
     -exportOptionsPlist build/ExportOptions-upload.plist -allowProvisioningUpdates
   ```
   `build/ExportOptions-upload.plist` (gitignored with the rest of `build/`,
   recreate if missing): `method` `app-store-connect`, `destination` `upload`,
   `teamID` `3BAMVTHBKF`, `signingStyle` `automatic`, `uploadSymbols` true,
   `manageAppVersionAndBuildNumber` false. The archive signs with the
   development identity and the export re-signs with a cloud-managed
   distribution certificate, so no distribution certificate appears in the
   keychain. Expect one warning: "Upload Symbols Failed … no dSYM for
   Sentry.framework". The Sentry package ships as a binary framework without
   its dSYM, so Apple's own crash reports lack Sentry frames; Sentry
   symbolicates its framework itself and the app's dSYM is unaffected.
   Steps 6a, 6b and 7 still apply; for 6a and 6b, `ARCHIVE` is
   `build/archives/MyBodegas-<ver>-<build>.xcarchive` instead of the Organizer
   path.
6a. **Upload debug symbols to Sentry** (#147 D6), so crash reports name
   `BodegasNYC` functions instead of addresses. Find the archive in
   Organizer (right-click → Show in Finder), then:
   ```sh
   export SENTRY_AUTH_TOKEN=$(cat ~/.config/bodegasnyc/sentry-token)
   ARCHIVE=~/Library/Developer/Xcode/Archives/<date>/<archive>.xcarchive
   sentry-cli debug-files upload --org heerheer --project my-bodegas-ios "$ARCHIVE/dSYMs"
   ```
6b. **Check the symbols match the binary** (#147 E8, AC 15; required on the
   first TestFlight build, a spot check after): the UUIDs of the archived app
   binary must be listed under Sentry → Settings → Debug Files.
   ```sh
   dwarfdump --uuid "$ARCHIVE/Products/Applications/BodegasNYC.app/BodegasNYC"
   ```
   A UUID missing from Debug Files means the upload took the wrong dSYMs;
   upload again from this archive before relying on crash reports.
7. **Tag the commit** you archived from, so the build maps back to source:
   ```sh
   git tag -a v1.0.0-3 -m "App Store build 3 of 1.0.0" && git push origin v1.0.0-3
   ```
   Format: `v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>` (builds 1 and 2
   predate semantic versioning and are tagged `v1.0-1` and `v1.0-2`).
8. **App Store Connect**: wait for processing (a few minutes to an hour),
   attach the build to the version, fill in "What's New", check the App
   Review notes still describe the build, then Submit for Review.
9. **TestFlight first** if the change touched location, sign-in or photo
   upload: install the processed build via TestFlight on your own phone
   before submitting. It is the same binary App Review will see.

## Runbook: analytics cleanup after account deletion

`delete-account` deletes the user's PostHog person with its events right
after the account (#147 DS4). It never fails the deletion over it: a missing
`POSTHOG_*` secret or a PostHog error is logged instead, with the user id
hashed. Weekly, and within 30 days of any deletion (the privacy policy's
promise):

1. Supabase dashboard → Edge Functions → `delete-account` → Logs, search for
   `analytics cleanup failed` and `analytics cleanup skipped`.
2. For each line, take the deleted user's id from Supabase → Authentication
   → Logs at the same time (the `user_deleted` entry), check it matches the
   logged hash (`printf %s <user-id> | shasum -a 256 | cut -c1-12`), then in
   PostHog → People search that id and delete the person with "Delete
   events" checked.
3. Crash reports in Sentry need no action: they expire after 90 days.

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

Packages that ship their own `PrivacyInfo.xcprivacy` (swift-crypto,
sentry-cocoa and posthog-ios do) are covered by Xcode when it aggregates the
manifests at archive time. After bumping Sentry or PostHog, compare their
manifests' collected data types and required-reason APIs with
`BodegasNYC/PrivacyInfo.xcprivacy` and the App Privacy answers above (#147):
```sh
find build/dd/SourcePackages -name PrivacyInfo.xcprivacy -path '*entry*' -o \
  -name PrivacyInfo.xcprivacy -path '*osthog*'
```
