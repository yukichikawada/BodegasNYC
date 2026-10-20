# TODOS

## QA

### Make BodegasNYCUITests reliable under scripts/run-tests.sh --ui

**What:** Get the UI test target to run to completion under `scripts/run-tests.sh --ui` without the simulator-clone hang, so UI flows can be asserted in CI.

**Why:** The riskiest UI paths (tap a pin to open detail, the first-run onboarding and tutorial flow) are covered only by scripted live QA on a branch simulator. An automated tap test would catch a Marker-to-Annotation or navigation regression before QA does.

**Context:** CLAUDE.md "Running tests": xcodebuild clones the destination simulator for `BodegasNYCUITests` and can hang launching onto the fresh clone with no internal timeout, so `--ui` runs usually hit the 3-minute cap and get killed. Start at the clone step in `scripts/run-tests.sh` (a pre-booted, pinned destination and `-parallel-testing-enabled NO` are the first things to try), then add one `XCUITest` that taps a pin and asserts the detail title. Surfaced by the 2026-10-19 eng review of the voice and first-run spec (decision R3/D5, TODO D12).

**Effort:** M
**Priority:** P3
**Depends on:** None

## Completed

### Create DESIGN.md with /design-consultation (done 2026-10-20)

`DESIGN.md` written from the DD1-DD16 contract plus D4-D6 from the consultation; code follow-up is #66, ideas #67/#68.
