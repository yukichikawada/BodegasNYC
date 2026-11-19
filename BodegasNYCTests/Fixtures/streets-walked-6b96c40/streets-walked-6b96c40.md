# Streets Walked store, schema of main 6b96c40

`streets-walked-6b96c40.store` is a real SwiftData store written by the Streets Walked schema as it
stood on main from 6b96c40 to 5204cdb (`WalkedPoint` with `storedRide`, `WalkedBlock`,
`WalkedMatchState` with `dayIndexVersion` and `estimatedThroughDay`, `WalkedDayBlock`, `WalkedDay`),
before #180 PR 2 added `WalkedPoint.importBatch` (eng E3). Named for 6b96c40 as the eng review asks;
no model file changed between that commit and 5204cdb.

How it was produced: a throwaway unit test (not committed), run through `scripts/run-tests.sh` on
2026-11-19 at 5204cdb, opened a file-backed `ModelContainer(for: Schema(StreetsWalkedSchema.models))`
and, on `StreetFixtures.cornerGrid(stamp: 1)`, saved `RideEvidenceTests`' three walks (block 100
walked, the slow ride on block 300, the later walk down block 201) with a `WalkedBlockStore` pass
after each: the first two with CoreMotion covering them and seeing the ride, the last with
`activity: .unavailable`. The store closed with an empty `-wal`, and
`sqlite3 ... "PRAGMA wal_checkpoint(TRUNCATE)"` returned `0|0|0`, so the `.store` file alone is
self-contained.

Contents: 29 `WalkedPoint`s, all matched, `storedRide` 0 on 8, 1 (walking) on 10, 2 (ride) on 11;
one `WalkedMatchState` with dataset stamp 1, day index version 1, no estimate day; three
`WalkedBlock`s with masks 100: 510, 200: 2, 201: 510; one `WalkedDay` and three `WalkedDayBlock`s.

`WalkHistoryImportUpgradeTests` copies it to a temporary directory before opening it. Never open it
in place.
