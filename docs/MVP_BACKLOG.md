# BodegasNYC — MVP Backlog

Companion to [`PRD.md`](./PRD.md) — tracks work still **in MVP scope** (contrast with
[`REACH_GOALS.md`](./REACH_GOALS.md), which is explicitly *out* of MVP scope). Each row is
written to be self-contained enough to feed a `/plan` session, then the `publish-plan` skill to
push the resulting plan to the Notion "Claude Plans" database for a Routine to pick up — same
pipeline `REACH_GOALS.md` uses.

Effort is a rough T-shirt size (S/M/L/XL), not an estimate. **Sign-off column:** whether this
needs your judgment call before a Routine builds it unattended, versus safe to hand off once its
dependencies are met — not a model-tier annotation.

## Resolved debt

**Unauthenticated bodega writes** (opened by PR #10, migration
`20260812013849_allow_anonymous_bodega_inserts.sql`, merged 2026-08-12) were reverted once Sign
in with Apple started working end-to-end — see migration
`20260815181145_revert_anonymous_bodega_inserts.sql`. `bodegas_insert` is back to
`to authenticated with check (auth.uid() = created_by)`, `created_by` is `NOT NULL` again, and
`AddBodegaViewModel.submit()` re-gates on `sessionStore.currentUserID`.

New UI work (Add Review/Photo/Flag below) should follow `AddBodegaViewModel`'s sign-in-gated
pattern (`sessionStore.currentUserID == nil` → present `SignInView`, matching PR #9's design) —
`reviews_insert`/`photos_insert`/`flags_insert` have always been `to authenticated`-only (see
`supabase/migrations/20260722043231_bodegas_reviews_photos_flags_rls.sql`).

## Shipped

**Add Review UI** — form to submit a rating + text review from the bodega detail page, editable
by the author, sign-in-gated via `AddBodegaViewModel`'s pattern. No backend changes; `reviews`'
existing `unique (bodega_id, author_id)` constraint drives client-side insert-vs-update routing.
Live-verified in Simulator 2026-08-16.

**Filter/Search** — filter the map and list by any combination of the five data points (AND
semantics) plus free-text name/address search (case- and diacritic-insensitive). Applied
client-side via a pure `BodegaFilter` value type against the bodegas each view model already
holds — no backend changes, and the `.all`/`.nearby` fetch paths are untouched. `BrowseView`
owns the single filter state (toolbar filter sheet + the list's `.searchable`), so switching
tabs keeps it. Covered by unit tests; not yet verified in Simulator.

**Flag-an-Issue UI** — flag a bodega (button next to "Add a Review"), a review, or a photo
(context menu; hidden on your own review) from the bodega detail page, with a reason picker plus
optional free text, sign-in-gated via the same pattern. No backend changes; auto-hide stays in
the existing `trg_flags_auto_hide` trigger, and the partial unique indexes' `23505` on a repeat
flag is surfaced as "You've already flagged this." Covered by unit tests; not yet live-verified
in Simulator.

**Add Photo UI** — "Add a Photo" `PhotosPicker` (library, single image) in the bodega detail
gallery, which now renders even with no photos yet. Picking opens a preview sheet whose Upload
button is sign-in-gated via the same pattern; the image is downscaled to at most 1600 px on the
long edge and re-encoded as JPEG (0.8) off the main actor (`PhotoImageEncoder`), then uploaded
via the existing `PhotoService.upload` and prepended to the gallery. No backend changes, no
`Info.plist` usage string (`PhotosPicker` is out-of-process). Covered by unit tests; not yet
live-verified in Simulator.

## Remaining MVP feature work

| Feature | Category | One-liner | Effort | Needs Your Sign-Off? | Notes / Dependencies |
|---|---|---|---|---|---|
| Edit Existing Bodega UI | Detail page | Any user can propose an edit to hours/data points on an existing bodega. `BodegaService.update()` already exists. | M | No — mechanical; can likely reuse `AddBodegaView`'s form components pre-filled with current values. | PRD §4.2 + §9: edits apply immediately, no approval queue (MVP assumption) — see [`REACH_GOALS.md`](./REACH_GOALS.md)'s "Edit-approval workflow" row if that assumption ever needs revisiting. |
| Duplicate-Bodega Check on Submit | Add-a-Bodega | Basic proximity check when submitting a new bodega to catch obvious duplicates. | S–M | **Yes** — exact UX (merge vs. reject vs. flag-for-review) is explicitly left unspecified in PRD §4.1. | Depends on picking a UX before building — don't let this get built ahead of that decision. |
| Onboarding Flow | Portfolio/Design | Custom onboarding that establishes tone immediately — not a generic permissions carousel. | M | **Yes** — needs your product voice/tone direction. | PRD §4.3/§8. |
| First-Run Tutorial | Portfolio/Design | Guided "add your first bodega" flow that teaches by doing, not static screens. | M | **Yes** — same, needs voice/tone direction and interaction design. | PRD §4.3/§8. |
| Custom Map↔List↔Detail Transitions | Portfolio/Design | Deliberate transitions between the three core views — map should never feel like it "goes away." | L | **Yes** — PRD §7 itself calls out that map-heavy screens deserve a focused `/plan` session once actually being built. | PRD §4.3/§8. Easy to underestimate — likely the largest single item here. |
| Personality-Driven Empty States | Portfolio/Design | Empty states with personality at every point a new user could hit one (no bodegas nearby, no reviews/photos yet, no streets walked yet). | S | **Yes** — needs your copy/voice. | PRD §4.3/§8. Cheapest of the design-pass items — good candidate to bundle with whichever feature naturally produces the empty state. |
| Delight Moment | Portfolio/Design | At least one genuine delight moment tied to a meaningful action — leading candidate is right after a user's first bodega gets added. | S–M | **Yes** — needs your creative direction on what the moment actually is. | PRD §4.3/§8. |

---

**Related:** [`PRD.md`](./PRD.md) — full product requirements. [`REACH_GOALS.md`](./REACH_GOALS.md)
— backlog for explicitly out-of-MVP-scope work.
