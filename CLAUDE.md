# BodegasNYC

## Running tests

Always run tests via `scripts/run-tests.sh`, invoked with `run_in_background: true`. Never call `xcodebuild test` directly.

By default it only runs `BodegasNYCTests` (fast, seconds). Pass `--ui` to also run `BodegasNYCUITests`. Every run passes `-parallel-testing-enabled NO`, so every test runs on the pinned device and xcodebuild never clones it; with parallel testing on, it fanned out to fresh "Clone N of" devices, the first UI launch on a clone took about a minute (#101), and on 2026-11-04 the unit path's clone hung at app install for the whole cap. Measured without clones: 45-55 s of testing when warm, about 3 minutes for a warm build plus the full run, about 7 minutes before testing starts when `build/dd` is cold (pass `TEST_TIMEOUT_SECONDS=900` for that first run). Caps: 8 minutes, 10 with `--ui`. Since macOS 27.2 (2026-11-04) the script runs under Xcode 27.2's toolchain when it is installed (`DEVELOPER_DIR`, overridable): Xcode 26.6's `xcodebuild test` can no longer reach a simulator's instruments service on this host, though it still builds, and it still archives the 1.0 App Store builds (`docs/RELEASE.md`). Xcode 27 replaces Simulator.app with DeviceHub; `simctl` is unchanged. UI tests launch the app with `-UITestFixtures` (DEBUG only, `BodegasNYC/App/UITestFixtures.swift`), which serves a fixture bodega through a `URLProtocol` instead of the network, plus `-firstRun.hasCompletedOnboarding YES` to skip onboarding; they never touch the hosted database.

The script pins the test destination to a specific simulator UDID (avoids ambiguous-destination clone spam from having 5 runtimes installed), skips SPM package-plugin trust validation (`-skipPackagePluginValidation`, needed for SwiftLintPlugins to run headlessly), deletes leftover shut-down "Clone N of ..." simulators from xcodebuild's testing device set before and after the run (never booted ones: that set is shared by every project on the Mac), shuts the pinned device down when the run ends if the run booted it (one that was already booted stays booted), hard-caps the run via `timeout` (default 480s / 8min, 600s / 10min with `--ui`; override with `TEST_TIMEOUT_SECONDS` or a trailing argument), serializes concurrent invocations from other worktrees via a lockfile, and builds into the checkout's own `build/dd` (gitignored) so a worktree's DerivedData is deleted with the worktree instead of piling up under `~/Library/Developer/Xcode/DerivedData`.

## Housekeeping

Builder and QA worktrees under `.claude/worktrees` are not removed automatically once they have
commits, and nothing removes them when their PR merges, so finished worktrees (some left locked)
accumulate. At the start of any orchestration session, and again after merging a batch of PRs,
run:

```sh
scripts/cleanup-worktrees.sh          # dry run: lists what would be removed and what is kept, and why
scripts/cleanup-worktrees.sh --apply  # unlocks + removes them, deletes their local branches, simulators and orphaned DerivedData
```

Only worktrees whose branch has a merged or closed PR (per `gh pr list`) are removed; a worktree
with an open PR, no PR, uncommitted tracked changes, or git activity in the last two hours (a
builder lane that has not committed yet looks like "no PR, tip on main") is kept and listed. Even
so, do not run `--apply` while a builder worktree is minutes old: wait for its first commit. Untracked `build/`
output does not count as uncommitted work. Squash merges mean commit ancestry proves nothing, so
PR state is the source of truth. The script also deletes `worktree-agent-*` scratch branches that
point at commits already on `main` and runs `scripts/sim-for-branch.sh delete` for each removed
branch. It never deletes remote branches. It also sweeps DerivedData folders (under
`~/Library/Developer/Xcode/DerivedData` and `~/Library/Developer/MobileBuildMCP/workspaces/*/DerivedData`)
whose recorded project path was a worktree of this repo that no longer exists; folders belonging to
other projects are left alone. Do not wire `--apply` into a SessionStart hook; the dry run is the
right thing to automate, the removal stays behind an explicit command.

## Orchestration and model routing

Work is tracked as GitHub issues (`gh issue list`). There is no Notion planning pipeline; ignore
references to "Claude Plans" / Routines in older docs.

Before a new body of work is briefed to a builder, it goes through gstack: `/spec` to turn the
intent into a spec, then `/plan-eng-review` and `/plan-design-review` (accept their "outside
voices" second-model passes). Attach the resulting spec/report to the GitHub issue. Small,
mechanical follow-ups to an already-reviewed spec don't need a fresh pass.

**Batch the review questions.** The owner almost always accepts the recommended option in
`/spec`, `/plan-eng-review`, and `/plan-design-review`, so do not walk them through decision
briefs one at a time. Run the skill's analysis to completion first, collect every decision it
would raise, and present them together: as few `AskUserQuestion` calls as possible (up to 4
questions per call), recommended option first and marked `(Recommended)`, each with a one-line
reason. A reply of "accept all" means take the recommended option for every item and continue
without re-asking. Two exceptions still get asked on their own: anything gstack classifies as
one-way (destructive ops, data-model or architecture forks) and any question whose answer
changes which later questions exist. Where the skill fires a question mid-phase and the rest of
the phase genuinely depends on it, batch what you can and say what is deferred.

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
  and tests pass, waits for the automated Claude review in CI to finish, addresses its findings
  (or says in the PR why one is dismissed), then **squash-merges it** with
  `gh pr merge --squash --delete-branch` and runs `scripts/cleanup-worktrees.sh --apply`. The
  owner does not gate merges and should not be made a bottleneck; the only things that wait on
  them are `needs-decision` issues and anything one-way (schema migrations against the hosted
  database, deleting data, anything that cannot be reverted with a follow-up PR).
- `.github/workflows/claude-code-review.yml` runs an automated Claude review on every PR as a
  second set of eyes. When reviewing in CI (Linux runner, no Xcode): read the diff against the
  conventions in this file and `docs/PRD.md`; do not try to run `xcodebuild`, the test script, or
  a simulator.
- Items that touch the same view (e.g. all three bodega-detail actions) are built as a stack:
  each later branch is based on the previous one and its PR targets that branch, so GitHub
  retargets to `main` as earlier PRs merge. Merge a stack bottom-up, one PR at a time, and let
  GitHub retarget the next PR before merging it. Independent items branch from `main` in
  parallel.

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

Machine-wide build cap: `~/.claude/CLAUDE.md` caps concurrent `xcodebuild` runs at two across every
session and project on this Mac (wait for a slot before `run-tests.sh` or any MobileBuildMCP build or
test call; the script's lockfile serializes only this project's runs) and keeps a simulator booted
only while its branch is building, installing or doing QA.

`.mobilebuildmcp/config.yaml` enables MobileBuildMCP's `ui-automation` workflow (snapshot_ui,
tap, type_text, swipe, long_press) so QA agents can drive the app, not just screenshot it. The
server reads it at startup; after changing it, reconnect the MCP server (`/mcp`) or restart the
session.

### Test account for live QA

Debug builds can sign in with email/password so authenticated flows can be exercised in the
Simulator without Sign in with Apple. Copy `~/.config/bodegasnyc/test-account.xcconfig` to
`Local.xcconfig` at the repo root (or symlink it: `ln -s ~/.config/bodegasnyc/test-account.xcconfig Local.xcconfig`),
then rebuild Debug: the sign-in sheet gains a "Sign in with test account" button. QA agents use
this instead of Sign in with Apple. `Local.xcconfig` is gitignored and pulled in by
`Config/Debug.xcconfig` via `#include?`, so without it the button is simply hidden; never commit
or print the credentials. The whole path is `#if DEBUG` and absent from Release builds.
The password must not contain `//` or `$`: xcconfig treats `//` as the start of a comment and
`$` as a variable expansion, so the value would be silently truncated or rewritten.

## Design System

Read `DESIGN.md` before visual or UI work: it defines the fonts, colors, spacing, and aesthetic
direction. Ask the user before departing from it. When reviewing or QA-ing UI, flag code that
doesn't match `DESIGN.md`. It supersedes the DD1 to DD16 comments on #21/#22/#24/#25 where they
differ (D5 amends DD1's title weight and width).
