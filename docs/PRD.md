# BodegasNYC — Product Requirements Document

**Status:** Draft v0.2
**Owner:** Yukichi Kawada
**Last updated:** 2026-07-21

> **About this document.** A PRD answers three questions before any code gets written: *what* are we building, *for whom*, and *how do we know it worked*. It intentionally stays implementation-light — architecture gets its own section below, but detailed UI design, exact schemas, and sprint planning are deliberately out of scope for this doc. Anything marked **Assumption** below is a judgment call made without your explicit confirmation — treat those as the first things to correct.

---

## 1. Overview & Problem Statement

NYC bodegas are dense, hyper-local, and full of useful variation (does this one have a cat? hot food? lotto?) — but they're systematically underrepresented on Google Maps and Apple Maps, which are built for chains and formally-registered businesses. The same is true of a wider category of informal city infrastructure: food carts, park chess tables, street performers, dog runs. None of it is well mapped, and the data that *would* make it useful (amenities, vibe, hours that are actually accurate) isn't something a business listing captures anyway — it's something only the people who actually go there know.

BodegasNYC is a crowdsourced, community-maintained map of NYC bodegas, built by the people who use them.

This project has a second, equally real goal: it's a portfolio piece. It needs to demonstrate native iOS craft — not just "does it work" but "does it feel considered" — through onboarding, transitions, and moments of delight, in addition to functioning as a genuinely useful app.

## 2. Goals & Success Criteria

**Goals**
1. Make it fast to find a bodega with the specific thing you need right now (cold beer, a lotto ticket, a cat to say hi to) via crowdsourced, structured data that Google/Apple Maps don't capture.
2. Make contributing data (adding a bodega, leaving a review, flagging something stale) low-friction enough that people actually do it.
3. Showcase native SwiftUI craft — onboarding, transitions, and interaction design — as a portfolio artifact.

**Success looks like**
- A meaningful chunk of bodegas in the developer's own neighborhood(s) cataloged with real data, used by the developer in daily life.
- The app is demo-ready for a portfolio review or interview walkthrough — cold-open to "wow" in under a minute.
- The core "add a bodega" and "find a bodega with X" loops work end-to-end with no manual data cleanup required.

**Non-Goals (v1)**
- No monetization (ads, subscriptions, sponsored listings).
- iOS only — no Android, no web app.
- NYC only — no multi-city support or city-selection UI.
- No real-time chat, gamification, or contributor leaderboards (see [Reach Goals](#6-out-of-scope--reach-goals)).

## 3. Target Users

| Persona | Description | Why they matter |
|---|---|---|
| **Primary — NYC regular** | Lives or works in NYC, has a few go-to bodegas already, wants to discover new ones with specific amenities. | The core user loop (find + contribute) is built for them. |
| **Secondary — Explorer/tourist** | Visiting or new to a neighborhood, wants a map layer Google/Apple can't give them. | Validates that crowdsourced data is useful to people with zero local knowledge. |
| **Tertiary — Portfolio reviewer** | An interviewer or peer evaluating this as a work sample. | Doesn't use the app for its data — evaluates it in the first 60 seconds on polish, onboarding, and interaction design. Shapes [Section 8](#8-design--portfolio-requirements) directly. |

## 4. MVP Scope (Bodegas Only)

Everything in this section is bodega-specific. Generalizing to other POI types is explicitly a reach goal (Section 6) — the MVP data model should be free to hard-code "bodega" as a concept rather than build a generic category system prematurely.

### 4.1 Core data model
Each bodega has:
- **The five signature data points** (each independently settable, community-editable): has a cat, serves hot food, sells cigarettes, sells beer, sells lotto tickets.
- Address (geocoded to a map pin).
- Hours of operation.
- Photos (host-uploaded by any user, not just the original submitter).
- Community rating (aggregate, e.g. 1–5 stars).
- Reviews (persistent text, tied to a user).

### 4.2 Functional requirements
- **Add a bodega:** any authenticated user can submit a new bodega (name, location via map-pin-drop or current location, the five data points, hours). Basic proximity check on submit to catch obvious duplicates (**Assumption:** exact duplicate-resolution UX — merge vs. reject vs. flag-for-review — is left as an implementation detail, not specified here).
- **Browse:** map view (pins) and list view, togglable, of nearby/all bodegas.
- **Filter/search:** by any combination of the five data points ("show me bodegas with a cat and hot food nearby") plus free-text name/address search.
- **Bodega detail page:** all data points, hours, address, photo gallery, reviews, aggregate rating, an "Add a review" / "Add a photo" / "Flag an issue" action set.
- **Reviews & ratings:** persistent (unlike chat — see Section 6), one review per user per bodega, editable by the author.
- **Photo uploads:** any authenticated user can add photos to a bodega's gallery.
- **Editing existing data:** any user can propose an edit to hours/data points on an existing bodega (**Assumption:** edits apply immediately rather than requiring approval, consistent with the lightweight-moderation model below — revisit if bad-faith edits become a problem).
- **Community flagging:** users can flag a review, photo, or bodega record as inaccurate/inappropriate. Content is auto-hidden after a flag-count threshold. No human moderation queue for v1.
- **Location permission:** **When-In-Use** only for the core bodega-finding flow. The app requests location on first map interaction (not at launch) with a clear one-line explanation of why ("to show bodegas near you") — no upfront permission-prompt wall. (See Section 5 for the separate, opt-in Always-permission flow used by the streets-walked feature — the two are never bundled into one ask.)
- **Auth:** Supabase Auth (email or a social provider — **Assumption:** exact provider set left as an implementation detail).

### 4.3 Required feature slots (not fully speced)
The following must exist as real, budgeted features in the MVP, even though their visual/interaction design is being deferred to a later design pass (per your direction):
- A custom onboarding flow (not just a permissions dialog).
- A first-run tutorial/coachmark moment.
- Deliberate transitions between map → list → detail views (not default push/pop).
- A personality-driven empty state (e.g., first-launch "no bodegas near you yet — be the first to add one").
- At least one designed "delight moment" (candidate: what happens right after a user successfully adds their first bodega).

## 5. Streets-Walked Heatmap (MVP)

A personal feature, separate from the bodega data model: the app tracks the streets a user has physically walked and renders them as a highlighted overlay on their own map view. **This moved from reach-goal to MVP at your explicit direction** — it was originally deferred pending confirmation (see the interrupted question in the prior session), and you've now confirmed it belongs in v1.

### 5.1 Functional requirements
- **Opt-in, off by default.** Enabling this is a distinct, separate action from granting the core When-In-Use location permission — a user can fully use the bodega-finding features of the app without ever touching this.
- **Background tracking.** To be meaningful, this needs location capture to continue while the app isn't in the foreground — nobody keeps a map app open while walking around, so a foreground-only version would produce a heatmap too sparse to be worth building. (**Assumption:** this is the "full background tracking" interpretation, not a foreground-only lite version — flag it if you actually meant the lighter version.)
- **Local-first storage** (**Assumption**): walked-street data is stored on-device by default (e.g. SwiftData), not synced to Supabase. This avoids shipping continuous personal location history to a backend before there's a clear reason to; cross-device sync is a later decision, not an MVP requirement.
- **User controls:** a way to view the heatmap, and a way to clear/delete the history entirely — not optional polish, but a baseline requirement for any feature built on continuous location capture.
- **Rendering:** a toggle-able overlay layer on the MapKit `Map` view (highlighted street segments), off by default over the standard bodega-pin view so the two don't visually compete.
- **Block model (#108):** raw fixes are kept as-is and map-matched on device to NYC street blocks (the city's CSCL centerline, `rw_type = 1`, bundled as `nyc-streets.bin` by `scripts/build-street-segments.py`). A block counts as walked once at least 6 of its 10 tenths were walked (contiguous coverage of 60% always counts, 40% never does), legs faster than 4 m/s, longer than 60 m, across a 20 min / 250 m gap or during a ride Motion & Fitness saw credit nothing. The map draws walked blocks in the `walked` indigo while history exists and Show on Map is on, recording or not; the Your Blocks sheet (Streets Walked menu) lists walked blocks out of every street block, citywide and per borough (Manhattan, Brooklyn, Queens, Bronx, Staten Island), with a percent rounded down ("<1%" under one). Matching runs in the foreground only; background deliveries just record.

### 5.2 Privacy & permission implications
- Requires **Always** location authorization (`NSLocationAlwaysAndWhenInUseUsageDescription`), requested as its own distinct, clearly-explained prompt — never bundled with the core app's When-In-Use ask (Section 4.2).
- **Assumption:** tracking technique defaults to continuous background location updates with a distance filter, not the coarser significant-change API — street-level resolution needs more precision than "moved to a new cell tower." This has real, currently-unmeasured battery cost and is worth revisiting once it's built and profiled on-device.
- App Store review scrutinizes background-location justifications closely; the strictly opt-in, separately-requested framing above exists specifically to keep that justification honest and narrow (this feature, not the whole app, needs it) rather than convenient.

## 6. Out of Scope / Reach Goals

Full backlog with effort/dependency notes lives in [`REACH_GOALS.md`](./REACH_GOALS.md), structured so each row can become its own future `/plan` session. Summary of what's deliberately *not* in the MVP:

- **Ephemeral per-bodega chat rooms** — a live chat tied to each bodega, messages expire (TTL) and are never persisted to storage, sidestepping moderation/retention concerns by design. Sketched at a concept level only; not built or fully speced for MVP.
- **Additional POI categories** — food carts/trucks, park chess players, street/park performers (e.g. Washington Square jazz), dog parks. Framed as a future generalized "POI type" abstraction the bodega data model could grow into, not a v1 concern.
- **Gamification** — contributor badges, leaderboards, streaks.
- **Manual moderation dashboard** — only becomes necessary if community flagging proves insufficient at scale.

## 7. Technical Architecture (Directional)

This section states direction and rationale, not final implementation design — architecture for specific screens (especially the map layer) should get its own `/plan` session once you're actually building them.

- **Platform:** Native iOS, SwiftUI, targeting the **latest major iOS version**. **Swift 6 with strict concurrency checking enabled** — a deliberate choice, not a default: you want hands-on experience with actor isolation, `Sendable` conformance, and `@MainActor`-isolated state, so the codebase should lean into that rather than opt out of checks. Expect ViewModels to be `@MainActor`-isolated by default and the data/networking layer (Supabase calls) to be modeled around `async/await` and actors rather than completion handlers or Combine.
- **Architecture pattern:** MVVM as the default. **Open question, not resolved here:** map-heavy screens tend to strain plain MVVM — camera position, annotation clustering, and region-change events often want a dedicated `MapViewModel` (or a small coordinator layered under it) decoupled from list/detail ViewModels, rather than one giant "MapScreenViewModel." Worth a focused `/plan` session once the map screen is actually being built, informed by how SwiftUI's `Map`/`MapContentBuilder` API (iOS 17+) behaves in practice. The streets-walked overlay (Section 5) adds a second source of map-layer state on top of bodega pins — worth folding into that same architecture discussion rather than bolting on separately.
- **Backend:** Supabase — Postgres (with the **PostGIS** extension for proximity/geo queries — e.g. "bodegas within 500m"), Supabase Auth for accounts, Supabase Storage for photos. Free tier comfortably covers solo/portfolio-scale usage; revisit if this ever gets real traffic.
- **Maps SDK:** **Apple MapKit**, recommended. Rationale: first-class native SwiftUI integration (`Map`/`MapContentBuilder`), no Google-style per-load billing model to manage, and it's the natural fit for an app whose whole premise is "the native maps ecosystem doesn't have this data." Google Maps documented here as the fallback alternative only if MapKit's places/search primitives ever prove insufficient (unlikely, since all POI data is your own).
- **Location:** Two-tier permission model. The core bodega-finding flow uses **When-In-Use** only (Section 4.2). The streets-walked heatmap (Section 5) is a separate, explicitly opt-in feature requiring **Always** authorization, requested on its own with its own justification — never bundled into the initial When-In-Use ask. Keeping them distinct is what keeps each permission request honest and narrowly scoped, both for the user and for App Store review.

## 8. Design & Portfolio Requirements

This app needs to read as *designed*, not just functional, within the first minute of use — that's the whole point of the portfolio framing. Full visual/interaction design is a later pass, but this PRD commits to these being real, budgeted feature slots (cross-referenced from Section 4.3):

- Onboarding that establishes tone immediately, not a generic permissions carousel.
- A first-run tutorial that teaches by doing (e.g., a guided "add your first bodega" flow) rather than static screens.
- Custom transitions between the three core views (map, list, detail) — this is a map-first app, so the map should never feel like it "goes away" during navigation.
- Empty states with personality at every point a new user could hit one (no bodegas nearby, no reviews yet, no photos yet, no streets walked yet).
- At least one moment of genuine delight, tied to a meaningful user action (first bodega added is the leading candidate).

## 9. Assumptions & Open Questions

Every judgment call made in this draft without your explicit sign-off, collected in one place:

1. **Streets-walked heatmap defaults to local-only storage** (Section 5.1) — not synced to Supabase. Flag if you want cross-device sync as an MVP requirement rather than a later addition.
2. **Streets-walked tracking defaults to full background tracking** with continuous, distance-filtered location updates (Section 5.1/5.2), not a foreground-only lite version — flag if you actually meant the lighter version, since the battery/permission tradeoffs differ meaningfully.
3. **No monetization** assumed for v1 (ads, subscriptions, sponsored placement all out of scope).
4. **Solo developer, no fixed ship date** — this PRD doesn't include a timeline/roadmap-with-dates, just MVP vs. reach-goal sequencing.
5. **NYC-only for v1** — no city-selection UX, no multi-region data model.
6. **Duplicate-bodega resolution** (Section 4.1) and **edit-approval flow** (Section 4.2) are both left as "immediate, no queue" for MVP, consistent with the lightweight-moderation decision — flag if you want anything stricter.
7. **Auth provider set** (email vs. social login vs. both) is unspecified — implementation detail for later.

---

**Related:** [`MVP_BACKLOG.md`](./MVP_BACKLOG.md) — tracked backlog for remaining in-scope MVP
work. [`REACH_GOALS.md`](./REACH_GOALS.md) — structured backlog for future, out-of-scope feature
planning.
