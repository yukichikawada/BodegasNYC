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

## Completed

### Paginate `BodegaService.fetchAll` past the 1,000-row PostgREST cap (done 2026-10-21)

`fetchAll()` pages with `.range` (1,000 rows a page, `created_at` then `id` descending) until a short page; #100.

### Create DESIGN.md with /design-consultation (done 2026-10-20)

`DESIGN.md` written from the DD1-DD16 contract plus D4-D6 from the consultation; code follow-up is #66, ideas #67/#68.
