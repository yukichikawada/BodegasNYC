# My Bodegas

A native iOS app for finding and sharing New York City bodegas: the corner
stores that Apple Maps and Google Maps treat as an afterthought. The map is
crowdsourced by the people who use them, with the things a business listing
never tells you: is there a cat, is there hot food, do they sell beer, lotto,
cigarettes, is there an ATM, and are the hours actually right.

Privacy policy: <https://yukichikawada.github.io/BodegasNYC/privacy/>
App Store: coming soon.

## What it does

- **Map and list of bodegas** near you, with pins clustered at low zoom and
  capsule labels at block zoom. Tap a pin for the detail screen: the six
  signature data points, hours, photos, rating and reviews.
- **Add a bodega** by dropping a pin or using your location, with a proximity
  check that catches duplicates before they are saved.
- **Photos, reviews and flags.** Anyone signed in can add photos (resized and
  re-encoded on device, so no camera or location metadata is uploaded), write
  a review, or flag a listing as closed or wrong.
- **Streets Walked**, an optional, off-by-default layer that records the
  streets you walk, including in the background, and highlights them on your
  own map. Raw GPS fixes are map-matched on device to the city's street
  centerlines, so a block counts as walked only when most of it was. Rides
  are filtered out using Motion & Fitness. The history never leaves the
  phone, and a "Your Blocks" sheet shows what share of the city, and of each
  borough, you have walked.
- **Sign in with Apple** for contributing; browsing works signed out.
- Onboarding, a learn-by-doing first-run tutorial, custom map-to-detail
  transitions, and empty states with some personality. The design system is
  in [`DESIGN.md`](DESIGN.md).

## How it is built

- **SwiftUI and Swift 6** with strict concurrency on, targeting the current
  major iOS release. ViewModels are `@MainActor`; networking and the
  block-matching pipeline are actors and `async/await`.
- **MapKit** (`Map` and `MapContentBuilder`) for the map, with a custom
  walked-streets overlay rendered from per-tile masks.
- **Supabase** for the backend: Postgres with PostGIS for the nearby query,
  Supabase Auth with Sign in with Apple, Supabase Storage for photos, and
  row-level security on every table. Migrations live in
  [`supabase/migrations`](supabase/migrations); the one edge function,
  `delete-account` (account deletion and Sign in with Apple revocation), lives
  in [`supabase/functions`](supabase/functions) with its Deno tests.
- **SwiftData** for the on-device Streets Walked history.
- **NYC Open Data.** `scripts/build-street-segments.py` turns the city's
  street centerline dataset into the compact `nyc-streets.bin` the app ships
  for map matching.
- **Tests.** Swift Testing unit tests for the view models, matching rules and
  networking, plus UI tests that launch the app against fixture data through
  a `URLProtocol` instead of the network. `scripts/run-tests.sh` runs them on
  a pinned simulator.

The product thinking is in [`docs/PRD.md`](docs/PRD.md). Work is tracked as
GitHub issues; features ship as squash-merged pull requests, each reviewed
by a second automated reviewer in CI before merge. The app was built with
Claude Code; the working rules it follows are in [`CLAUDE.md`](CLAUDE.md).

## Repository layout

```
BodegasNYC/            App target
  App/                 App delegate, first-run state, UI-test fixtures (DEBUG only)
  Auth/                Supabase session store, Sign in with Apple
  Location/            Permission handling, WalkRecorder (background recording)
  Streets/             Street grid, block matching, walked-block store and overlay
  Media/               Photo re-encoding
  Networking/          Supabase services (bodegas, reviews, photos, flags, account)
  Models/  ViewModels/  Views/
  Resources/           nyc-streets.bin
BodegasNYCTests/       Unit tests (Swift Testing)
BodegasNYCUITests/     UI tests against fixture data
supabase/              Hosted project config, migrations and edge functions
  functions/           delete-account (Deno; `deno test` from its folder)
scripts/               Test runner, simulator helpers, street-data build
docs/                  PRD, release checklist, privacy policy (served by GitHub Pages)
```

## Running it

You need Xcode 26 on macOS. Open `BodegasNYC.xcodeproj`, pick a simulator and
run. The app talks to the hosted Supabase project; its URL and anon key are
build settings and the anon key is meant to ship in the client, with
row-level security doing the real access control. Sign in with Apple needs a
device or a simulator signed into an Apple Account.

Run the tests with:

```sh
scripts/run-tests.sh         # unit tests, a few seconds
scripts/run-tests.sh --ui    # plus the UI tests
```

Releases are built and uploaded by hand from Xcode; the steps are in
[`docs/RELEASE.md`](docs/RELEASE.md).
