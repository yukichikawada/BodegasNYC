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

**What:** After PR 2 is on `main`, run pin → detail → swipe-back five times on a device and confirm the pin stays visible and aligned.

**Why:** Apple forum thread 807715 reports the source view vanishing only on device, which simulator QA cannot see.

**Context:** #23 T1, `BrowseMotion.PinToDetail`.

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
