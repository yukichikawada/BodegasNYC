# TODOS

## QA

### Add the #20 duplicate-check UI tests

**What:** Cover the #20 duplicate-check flows in `BodegasNYCUITests`. The target now runs to completion under `scripts/run-tests.sh --ui` (#101: `-parallel-testing-enabled NO`, so no simulator clones) and has a pin-tap-to-detail test on the DEBUG `-UITestFixtures` seam (`BodegasNYC/App/UITestFixtures.swift`).

**Why:** Each case is covered today only by live QA on a branch simulator.

**Context:** The fixture seam answers every Supabase request through a `URLProtocol`, so these cases need it extended: a `nearby_bodegas` response with a match within 50 m, an insert response, a stalled RPC, and a signed-out session. Cases (#20 eng review D9):

- Submit with a bodega within 50 m → the "Is this one of these?" sheet → tap a match → the add sheet closes and that bodega's detail is pushed.
- Submit with a match → "No, It's New" → inserted, the pin drops.
- Submit with a match → swipe the sheet down → the form is intact; Submit again → the sheet again.
- Signed out, Submit with a match → "No, It's New" → the half sheet is gone, then the sign-in sheet presents.
- Cancel while the check is running (stalled RPC) → no row is inserted.

**Effort:** M
**Priority:** P3
**Depends on:** #101

### Check the zoom swipe-back on a physical iPhone

**What:** After PR 2 is on `main`, run pin → detail → swipe-back five times on a device and confirm the pin stays visible and aligned. Then, once #150 is on `main`, pin → detail → Show on Map: the page shrinks into the pin where it is, then the camera centres it (eng review R3). Also from the List: Show on Map five times, no frozen search field over the map (the pop runs one main-actor turn after the tab switch; timing-sensitive). While there, open a detail with Xcode's memory gauge on `main` and on the #150 build: on the simulator the live preview added ~45 MB to the first detail open (~36 MB kept) and ~10 MB per later visit, over the eng review's 40 MB gate; the owner shipped it (R1 reopened 2026-11-02). If the device shows the detail pushing memory, swap the preview for an `MKMapSnapshotter` image: it is one file, `BodegaDetailMap.swift`.

**Why:** Apple forum thread 807715 reports the source view vanishing only on device, which simulator QA cannot see. Simulator RSS overstates device memory, so the preview's real cost is unknown until measured there.

**Context:** #23 T1, `BrowseMotion.PinToDetail`; #150 PR #153 Test plan for the simulator numbers.

**Effort:** S
**Priority:** P2
**Depends on:** PR 2 merged

## Data points

### Unknown vs no for the six data points

**What:** Decide whether each data point should carry unknown / no / yes instead of defaulting to no, and spec it for all six at once: nullable columns, filter semantics, the detail cue, the form control, onboarding copy.

**Why:** A bodega nobody has checked reads "No" for every point and is hidden by every Must Have filter. ATM is the first point whose default is wrong for most rows, since most NYC bodegas have one (#141 reviews).

**Context:** #141 eng D9 and design DS3. `BodegaDetailSections.swift` renders presence by shape plus contrast; `BodegaFilter.Amenity.isSatisfied(by:)` is the filter; the columns are in `20260722043224_create_bodegas_table.sql` and `20261030120000_add_bodega_has_atm.sql`.

**Effort:** L
**Priority:** P2
**Depends on:** #141 merged and an owner product decision

## Photos

### Edit a photo's caption after upload

**What:** Let the uploader change or clear a photo's caption once it is up: an RLS update policy on `public.photos` limited to `caption` (a column grant or a trigger, so `is_hidden`, `storage_path` and the rest stay immutable), plus an edit action in the photo viewer's menu for your own photos.

**Why:** #107 locks a caption once its first upload attempt starts (eng O1), so a typo is permanent today; the only fix is flagging the photo.

**Context:** #107 eng review TODO1 (D11) and spec D4. There is no update policy on `photos` now (`20260722043231_bodegas_reviews_photos_flags_rls.sql`); the caption column and its 1-140 character check land in `20261023120000_add_photo_caption.sql` (#107 PR 2). Keep the trim and empty-to-NULL rule from `AddPhotoViewModel.normalizedCaption(_:)`.

**Effort:** M
**Priority:** P3
**Depends on:** #107

## Accounts

### Apple server-to-server notifications for Sign in with Apple

**What:** An edge function registered as the Sign in with Apple server-to-server notification endpoint (developer portal → the app's Sign in with Apple configuration) that receives Apple's signed JWT events (`consent-revoked`, `account-delete`, `email-disabled`/`email-enabled`) and, for `consent-revoked` and `account-delete`, runs the same server-side deletion as `delete-account` (#127) for the matching Apple identity.

**Why:** When a user removes My Bodegas from their Apple ID in Settings instead of deleting in the app, nothing tells us today; their Supabase account, reviews, photos and flags stay until they sign in again and delete.

**Pros:** Closes the one deletion path that bypasses the app; reuses the #127 sweep and `deleteUser` code.

**Cons:** A public endpoint to register and secure (verify Apple's JWT signature against Apple's JWKS); a second function to deploy by hand; no user has hit the case yet.

**Context:** #127 eng review D9 (2026-10-30). Start from `supabase/functions/delete-account` once it exists: factor the revoke-free part (sweep + `deleteUser`) into a shared helper and call it from the new function after verifying the event JWT. Apple's events arrive as a JSON body with a `payload` JWT whose `events` claim names the type and the user's `sub`.

**Effort:** M
**Priority:** P3
**Depends on:** #127 merged and the `delete-account` function deployed

## Completed

### Paginate `BodegaService.fetchAll` past the 1,000-row PostgREST cap (done 2026-10-21)

`fetchAll()` pages with `.range` (1,000 rows a page, `created_at` then `id` descending) until a short page; #100.

### Create DESIGN.md with /design-consultation (done 2026-10-20)

`DESIGN.md` written from the DD1-DD16 contract plus D4-D6 from the consultation; code follow-up is #66, ideas #67/#68.

## Design

### Lift every detail-page button to a 44pt target

**What:** `BodegaDetailView`'s four `DetailButtonRow`s (Directions/Show on Map, Add a Photo, Add a Review, Flag an Issue) use the default control size, about 34pt tall. Bring them to DESIGN.md's 44pt minimum in one pass (`.controlSize(.large)` or a 44pt min-height label), so the page keeps one button height.

**Why:** DESIGN.md Layout: "44pt minimum for every target"; one-handed sidewalk use. Raised by Codex in the #150 design review (DS11); the new row matched the page rather than introduce two heights.

**Context:** `BodegasNYC/Views/BodegaDetailSections.swift:118` (`DetailButtonRow`), `BodegaDetailView.swift`. Check the AX stacking and the side-by-side fit on 375pt after the change; update DESIGN.md Buttons.

**Effort:** S
**Priority:** P2
**Depends on:** #150 merged

### Rename the Streets Walked "Show on Map" toggle to "Show Blocks"

**What:** `AppCopy.showOnMapToggle` ("Show on Map", the walked-blocks visibility toggle in the Streets Walked menu) shares its label with the detail's Show on Map button since #150. Rename the toggle "Show Blocks" (it shows your blocks) in `AppCopy`, DESIGN.md (the Streets Walked menu line and #108 row) and any UI test that finds it by label.

**Why:** Two controls, one label, two meanings. #150 design review D19.

**Context:** `BodegasNYC/Copy/AppCopy.swift:207,348`, `BodegasNYC/Views/MapScreenView+WalkedBlocks.swift`.

**Effort:** S
**Priority:** P3
**Depends on:** #150 merged

### Probe VoiceOver focus onto the spotlit pin after Show on Map

**What:** After Show on Map, VoiceOver hears "<Name>. On the map." (#150 DS9) but focus stays where the tab switch's screenChanged put it. Probe on a device whether `AccessibilityFocusState` (or a `.layoutChanged` post with the annotation's hosted view) can land focus on the spotlit pin through MapKit's annotation hosting; if it can, replace the announcement with focus.

**Why:** A VoiceOver user asked to see this bodega; landing on it beats being told about it.

**Context:** `BodegasNYC/Views/MapScreenView+PinToDetail.swift` (`HeldPinView`, `PinMotionState`), `BrowseView+Content.swift` (`tabSelection`). Known pitfall: `Map` re-renders annotation content only from observable state the view reads itself.

**Effort:** S
**Priority:** P3
**Depends on:** #150 merged
