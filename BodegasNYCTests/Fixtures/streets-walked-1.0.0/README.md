# Streets Walked store, 1.0.0 schema

`streets-walked-1.0.0.store` is a real SwiftData store written by the 1.0.0 Streets Walked schema
(`WalkedPoint`, `WalkedBlock`, `WalkedMatchState`) at commit a41cdf7, before #170 changed any model.

How it was produced: a throwaway unit test (not committed), run through `scripts/run-tests.sh` on
2026-11-18, opened a file-backed `ModelContainer(for: Schema(StreetsWalkedSchema.models))`, saved
the first 40 fixes of `WalkedBlocksPerformanceTests.manhattanWalk(fixes: 50, grid: StreetGrid.loadBundled())`,
ran a `WalkedBlockStore` pass (`activity: .unavailable`), saved the other 10 and ran a second pass.
The store closed with an empty `-wal`, and `sqlite3 ... "PRAGMA wal_checkpoint(TRUNCATE)"` confirmed
nothing was left to checkpoint, so the `.store` file alone is self-contained.

Contents: 50 `WalkedPoint`s, all matched; one `WalkedMatchState` with dataset stamp 1792226103;
six `WalkedBlock`s with masks 3: 1023, 5: 1023, 6: 1023, 14: 511, 23: 511, 24: 255.

`StreetsWalkedMigrationTests` copies it to a temporary directory before opening it. Never open it in place.
