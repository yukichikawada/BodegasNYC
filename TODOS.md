# TODOS

## QA

### Make BodegasNYCUITests reliable under scripts/run-tests.sh --ui

**What:** Get the UI test target to run to completion under `scripts/run-tests.sh --ui` without the simulator-clone hang, so UI flows can be asserted in CI.

**Why:** The riskiest UI paths (tap a pin to open detail, the first-run onboarding and tutorial flow) are covered only by scripted live QA on a branch simulator. An automated tap test would catch a Marker-to-Annotation or navigation regression before QA does.

**Context:** CLAUDE.md "Running tests": xcodebuild clones the destination simulator for `BodegasNYCUITests` and can hang launching onto the fresh clone with no internal timeout, so `--ui` runs usually hit the 3-minute cap and get killed. Start at the clone step in `scripts/run-tests.sh` (a pre-booted, pinned destination and `-parallel-testing-enabled NO` are the first things to try), then add one `XCUITest` that taps a pin and asserts the detail title. Surfaced by the 2026-10-19 eng review of the voice and first-run spec (decision R3/D5, TODO D12).

**Effort:** M
**Priority:** P3
**Depends on:** None

## Design

### Create DESIGN.md with /design-consultation

**What:** Run `/design-consultation` and move the interim visual contract (onboarding page contract, pin contract, `MapBottomCard` grid, `pin`/`catPin` colors, the one slot transition) out of the spec comments on #21/#22/#24/#25 into a DESIGN.md.

**Why:** Future features and design reviews calibrate against one file instead of re-deciding card radius, tints and type per feature.

**Context:** The 2026-10-19 design review of the voice and first-run spec found no DESIGN.md and wrote tokens into the spec as DD1, DD3 and DD13. PRD §8 defers the full visual pass; the trigger is the first UI work after the #24 → #21 → #22 → #25 stack merges. Start from the DD13 block in the design-review comment on #24.

**Effort:** M
**Priority:** P3
**Depends on:** The #24/#21/#22/#25 stack merged

## Completed
