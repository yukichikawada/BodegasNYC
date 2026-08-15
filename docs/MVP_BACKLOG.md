# BodegasNYC — MVP Backlog

Companion to [`PRD.md`](./PRD.md) — tracks work still **in MVP scope** (contrast with
[`REACH_GOALS.md`](./REACH_GOALS.md), which is explicitly *out* of MVP scope). Each row is
written to be self-contained enough to feed a `/plan` session, then the `publish-plan` skill to
push the resulting plan to the Notion "Claude Plans" database for a Routine to pick up — same
pipeline `REACH_GOALS.md` uses.

Effort is a rough T-shirt size (S/M/L/XL), not an estimate. **Sign-off column:** whether this
needs your judgment call before a Routine builds it unattended, versus safe to hand off once its
dependencies are met — not a model-tier annotation.

## Known debt (not a feature — a must-revert)

**Unauthenticated bodega writes are currently open on the live Supabase project** (PR #10,
migration `20260812013849_allow_anonymous_bodega_inserts.sql`, merged 2026-08-12). Sign in with
Apple was blocked on Apple Developer Program enrollment, so `AddBodegaViewModel.submit()` no
longer requires a session, `bodegas_insert` RLS accepts the `anon` role, and `bodegas.created_by`
is nullable. This directly contradicts PRD §4.2 ("any *authenticated* user can submit a new
bodega") and is a public, unrate-limited write hole for as long as it's in place (the Supabase
anon key ships inside the app binary and isn't a secret).

**Trigger to revert:** Apple Developer Program enrollment clears and Sign in with Apple actually
works end-to-end. **Revert path:** restore `NOT NULL` on `created_by`, narrow `bodegas_insert`
back to `to authenticated with check (auth.uid() = created_by)`, restore the
`sessionStore.currentUserID` guard in `submit()`, and restore the two tests deleted (not
commented out) in PR #10 — `submitRequiresSignInWhenNoSessionAndSendsNoRequest` and
`dismissSignInPromptResetsToIdleSoASecondSubmitReasksForSignIn` — from git history.

**Important for the rows below:** only `bodegas_insert` got the anon-role carve-out —
`reviews_insert`/`photos_insert`/`flags_insert` are still `to authenticated`-only (see
`supabase/migrations/20260722043231_bodegas_reviews_photos_flags_rls.sql`). New UI work (Add
Review/Photo/Flag below) should follow `AddBodegaViewModel`'s *original* gated pattern
(`sessionStore.currentUserID == nil` → present `SignInView`, matching PR #9's design) — **not**
its current temporarily-bypassed state. Don't propagate the anon carve-out to these.

## Remaining MVP feature work

| Feature | Category | One-liner | Effort | Needs Your Sign-Off? | Notes / Dependencies |
|---|---|---|---|---|---|
| Add Review UI | Detail page | Form to submit a rating + text review from the bodega detail page. `ReviewService` backend already exists. | S | No — mechanical; follow `AddBodegaViewModel`'s original sign-in-gated pattern. | PRD §4.2: one review per user per bodega, editable by author. `reviews_insert`/`reviews_update` RLS already `authenticated`-only, no backend changes needed. |
| Add Photo UI | Detail page | Image picker + upload flow to add a photo to a bodega's gallery. `PhotoService` backend already exists. | M | No — mechanical; same sign-in-gated pattern. | Needs `PhotosPicker` (or camera) integration — more UI surface than Add Review. `photos_insert` RLS already `authenticated`-only. |
| Flag-an-Issue UI | Detail page | Flag a bodega/review/photo as inaccurate or inappropriate. `FlagService` backend already exists. | S | No — mechanical; same sign-in-gated pattern. | PRD §4.2: auto-hide after a flag-count threshold, no moderation queue for v1 — that trigger logic should already exist server-side; confirm before assuming it needs building too. |
| Edit Existing Bodega UI | Detail page | Any user can propose an edit to hours/data points on an existing bodega. `BodegaService.update()` already exists. | M | No — mechanical; can likely reuse `AddBodegaView`'s form components pre-filled with current values. | PRD §4.2 + §9: edits apply immediately, no approval queue (MVP assumption) — see [`REACH_GOALS.md`](./REACH_GOALS.md)'s "Edit-approval workflow" row if that assumption ever needs revisiting. |
| Filter/Search | Browse | Filter by any combination of the five data points, plus free-text name/address search. | M | No — mechanical; data model and query surface already support it. | PRD §4.2. `nearby_bodegas` RPC pattern (from Add-a-Bodega's proximity work) may be a useful reference for how filters compose with the existing fetch paths. |
| Duplicate-Bodega Check on Submit | Add-a-Bodega | Basic proximity check when submitting a new bodega to catch obvious duplicates. | S–M | **Yes** — exact UX (merge vs. reject vs. flag-for-review) is explicitly left unspecified in PRD §4.1. | Depends on picking a UX before building — don't let this get built ahead of that decision. |
| Onboarding Flow | Portfolio/Design | Custom onboarding that establishes tone immediately — not a generic permissions carousel. | M | **Yes** — needs your product voice/tone direction. | PRD §4.3/§8. |
| First-Run Tutorial | Portfolio/Design | Guided "add your first bodega" flow that teaches by doing, not static screens. | M | **Yes** — same, needs voice/tone direction and interaction design. | PRD §4.3/§8. |
| Custom Map↔List↔Detail Transitions | Portfolio/Design | Deliberate transitions between the three core views — map should never feel like it "goes away." | L | **Yes** — PRD §7 itself calls out that map-heavy screens deserve a focused `/plan` session once actually being built. | PRD §4.3/§8. Easy to underestimate — likely the largest single item here. |
| Personality-Driven Empty States | Portfolio/Design | Empty states with personality at every point a new user could hit one (no bodegas nearby, no reviews/photos yet, no streets walked yet). | S | **Yes** — needs your copy/voice. | PRD §4.3/§8. Cheapest of the design-pass items — good candidate to bundle with whichever feature naturally produces the empty state. |
| Delight Moment | Portfolio/Design | At least one genuine delight moment tied to a meaningful action — leading candidate is right after a user's first bodega gets added. | S–M | **Yes** — needs your creative direction on what the moment actually is. | PRD §4.3/§8. |

---

**Related:** [`PRD.md`](./PRD.md) — full product requirements. [`REACH_GOALS.md`](./REACH_GOALS.md)
— backlog for explicitly out-of-MVP-scope work.
