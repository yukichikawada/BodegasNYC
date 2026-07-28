# BodegasNYC

## Running tests

Always run tests via `scripts/run-tests.sh`, invoked with `run_in_background: true`. Never call `xcodebuild test` directly.

By default it only runs `BodegasNYCTests` (fast, seconds, no simulator clone). Pass `--ui` to also run `BodegasNYCUITests` -- xcodebuild reliably clones the destination simulator for that target and can hang trying to launch onto the fresh clone with no internal timeout covering that phase. `--ui` runs share the same 3-minute cap as everything else, so in practice a hung UI test run will reliably get killed rather than complete -- that's a known limitation, not a bug in the script.

The script pins the test destination to a specific simulator UDID (avoids ambiguous-destination clone spam from having 5 runtimes installed), skips SPM package-plugin trust validation (`-skipPackagePluginValidation`, needed for SwiftLintPlugins to run headlessly), sweeps up any stray "Clone N of ..." simulators before and after the run, hard-caps the run via `timeout` (default 180s / 3min; override with `TEST_TIMEOUT_SECONDS` or a trailing argument), and serializes concurrent invocations from other worktrees via a lockfile.
