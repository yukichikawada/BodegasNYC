# BodegasNYC

## Running tests

Always run tests via `scripts/run-tests.sh`, invoked with `run_in_background: true`. Never call `xcodebuild test` directly.

By default it only runs `BodegasNYCTests` (fast, seconds, no simulator clone). Pass `--ui` to also run `BodegasNYCUITests` -- xcodebuild reliably clones the destination simulator for that target and can hang trying to launch onto the fresh clone with no internal timeout covering that phase. `--ui` runs share the same 3-minute cap as everything else, so in practice a hung UI test run will reliably get killed rather than complete -- that's a known limitation, not a bug in the script.

The script pins the test destination to a specific simulator UDID (avoids ambiguous-destination clone spam from having 5 runtimes installed), skips SPM package-plugin trust validation (`-skipPackagePluginValidation`, needed for SwiftLintPlugins to run headlessly), sweeps up any stray "Clone N of ..." simulators before and after the run, hard-caps the run via `timeout` (default 180s / 3min; override with `TEST_TIMEOUT_SECONDS` or a trailing argument), and serializes concurrent invocations from other worktrees via a lockfile.

## Orchestration and model routing

Work is tracked as GitHub issues (`gh issue list`). There is no Notion planning pipeline; ignore
references to "Claude Plans" / Routines in older docs.

When Claude Code orchestrates work with subagents:

- The orchestrator runs on the session's own model (Fable). It plans, briefs, reviews results,
  and merges. It does not implement features itself when a builder subagent is in flight on them.
- **Builder subagents run on Opus** (`model: "opus"`), one per issue, each in its own git
  worktree (`isolation: "worktree"`), branching from `main`. Use a cheaper model only for
  trivially mechanical tasks (doc moves, renames).
- **QA subagents run on Sonnet** (`model: "sonnet"`) unless the review genuinely needs more
  (deep concurrency reasoning, security). QA reviews the diff against the issue, runs
  `scripts/run-tests.sh`, builds the app, and reports findings; it does not land fixes.
- Every feature lands as a PR that references its issue (`Closes #N`), with the "Summary / Bugs
  found / Test plan" body shape used by past PRs. The orchestrator opens the PR once QA is clean
  and tests pass; **the owner merges** (squash). Claude does not merge PRs.
- Items that touch the same view (e.g. all three bodega-detail actions) are built as a stack:
  each later branch is based on the previous one and its PR targets that branch, so GitHub
  retargets to `main` as earlier PRs merge. Independent items branch from `main` in parallel.

## Simulators for live runs

Unit tests always go through `scripts/run-tests.sh` (pinned device, lockfile). For anything that
launches the app — `build_run_sim`, screenshots, manual QA — each branch/worktree uses its own
simulator so parallel runs never overwrite each other's install:

```sh
UDID=$(scripts/sim-for-branch.sh udid)        # creates + boots "BodegasNYC-<branch>" if needed
scripts/sim-for-branch.sh delete               # when the PR is merged or abandoned
```

Pass the UDID as the simulator id to MobileBuildMCP or `-destination "platform=iOS Simulator,id=$UDID"`.
Never run the app on the test script's pinned "iPhone 17 Pro" device.
