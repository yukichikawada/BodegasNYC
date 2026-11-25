import Foundation
import SwiftData

/// The per-day rows as `WalkedBlockStore` holds them in memory (#170 eng A3).
nonisolated struct WalkedDayRows: Sendable, Equatable {
    var masks: [WalkedDayKey: [UInt32: UInt16]] = [:]
    var meters: [WalkedDayKey: Double] = [:]
    var estimatedThroughDay: WalkedDayKey?

    init(
        masks: [WalkedDayKey: [UInt32: UInt16]] = [:],
        meters: [WalkedDayKey: Double] = [:],
        estimatedThroughDay: WalkedDayKey? = nil
    ) {
        self.masks = masks
        self.meters = meters
        self.estimatedThroughDay = estimatedThroughDay
    }

    init(_ days: [WalkedDayKey: BlockMatcher.DayDelta], estimatedThroughDay: WalkedDayKey?) {
        for (day, delta) in days {
            if !delta.masks.isEmpty { masks[day] = delta.masks }
            meters[day] = delta.meters
        }
        self.estimatedThroughDay = estimatedThroughDay
    }

    /// An incremental pass's delta: masks ORed, meters added.
    mutating func merge(_ days: [WalkedDayKey: BlockMatcher.DayDelta]) {
        for (day, delta) in days {
            if !delta.masks.isEmpty { masks[day, default: [:]].merge(delta.masks) { $0 | $1 } }
            meters[day, default: 0] += delta.meters
        }
    }
}

// Day rows (#170): written in the pass's one `save()` beside the masks, and
// read back as `WalkedHistory` for Your Walks.
nonisolated extension WalkedBlockStore {
    /// What a pass staged in the day rows, applied in memory once it saves.
    enum DayWrite {
        /// Every day row (a rebuild or backfill).
        case replaced([WalkedDayKey: BlockMatcher.DayDelta])
        /// An incremental pass's per-day delta.
        case merged([WalkedDayKey: BlockMatcher.DayDelta])
    }

    /// Stages a pass's day rows: a rebuild replaces them, an incremental
    /// pass merges into them, and a backfill replaces them clamped to the
    /// saved masks (eng A1).
    func stageDays(
        _ kind: WalkedPassKind,
        _ days: [WalkedDayKey: BlockMatcher.DayDelta],
        in context: ModelContext
    ) throws -> DayWrite {
        switch kind {
        case .rebuild: try writeDays(replacingWith: days, in: context)
        case .incremental: try writeDayIncrement(days, in: context)
        case .backfill: try writeDays(replacingWith: clampedToSavedMasks(days, in: context), in: context)
        }
    }

    /// The estimate a pass records (eng E2): none for an incremental pass,
    /// which leaves the saved value alone; a rebuild judges by CoreMotion's
    /// 7 days, a backfill (no CoreMotion) by every unknown leg, unless it
    /// re-derives day rows that already existed: then the saved estimate
    /// stands (#192 eng E4).
    func estimatedThroughDay(_ plan: Plan, found evidence: [UUID: RideEvidence]) -> WalkedDayKey? {
        guard plan.kind != .incremental else { return nil }
        if plan.kind == .backfill, plan.keepsSavedEstimate { return plan.savedEstimate }
        return WalkedEstimate.throughDay(
            plan.snapshots,
            found: evidence,
            now: now(),
            window: WalkedEstimate.askableWindow(for: plan.kind)
        )
    }

    /// Stages the match state: the bundle's stamp, and after a rebuild or
    /// backfill the day index version and the estimate (eng E2).
    func stageState(_ kind: WalkedPassKind, estimatedThroughDay: WalkedDayKey?, in context: ModelContext) throws {
        let state = try context.fetch(FetchDescriptor<WalkedMatchState>()).first ?? {
            let inserted = WalkedMatchState(datasetStamp: grid.datasetStamp)
            context.insert(inserted)
            return inserted
        }()
        state.datasetStamp = Int(grid.datasetStamp)
        guard kind != .incremental else { return }
        state.dayIndexVersion = Self.dayIndexVersion
        state.estimatedThroughDay = estimatedThroughDay?.value
    }

    /// Replaces every day row with `days`, updating rows in place or
    /// deleting them, never deleting and re-inserting one key in one save.
    func writeDays(
        replacingWith days: [WalkedDayKey: BlockMatcher.DayDelta],
        in context: ModelContext
    ) throws -> DayWrite {
        var remaining = days.mapValues(\.masks)
        for row in try context.fetch(FetchDescriptor<WalkedDayBlock>()) {
            if let mask = remaining[row.dayKey]?.removeValue(forKey: row.physicalID) {
                if row.mask != mask { row.mask = mask }
            } else {
                context.delete(row)
            }
        }
        for (day, masks) in remaining {
            for (physicalID, mask) in masks {
                context.insert(WalkedDayBlock(day: day, physicalID: physicalID, mask: mask))
            }
        }
        var meters = days.mapValues(\.meters)
        for row in try context.fetch(FetchDescriptor<WalkedDay>()) {
            if let value = meters.removeValue(forKey: row.dayKey) {
                if row.meters != value { row.meters = value }
            } else {
                context.delete(row)
            }
        }
        for (day, value) in meters {
            context.insert(WalkedDay(day: day, meters: value))
        }
        return .replaced(days)
    }

    /// ORs an incremental pass's day masks into the rows of the days it
    /// touches (usually one) and adds its meters. Fetches only those days.
    func writeDayIncrement(
        _ days: [WalkedDayKey: BlockMatcher.DayDelta],
        in context: ModelContext
    ) throws -> DayWrite {
        guard !days.isEmpty else { return .merged([:]) }
        let touched = days.keys.map(\.value)
        var remaining = days.mapValues(\.masks)
        let rows = try context.fetch(
            FetchDescriptor<WalkedDayBlock>(predicate: #Predicate { touched.contains($0.day) })
        )
        for row in rows {
            guard let bits = remaining[row.dayKey]?.removeValue(forKey: row.physicalID) else { continue }
            let merged = row.mask | bits
            if merged != row.mask { row.mask = merged }
        }
        for (day, masks) in remaining {
            for (physicalID, mask) in masks {
                context.insert(WalkedDayBlock(day: day, physicalID: physicalID, mask: mask))
            }
        }
        var meters = days.mapValues(\.meters)
        for row in try context.fetch(FetchDescriptor<WalkedDay>(predicate: #Predicate { touched.contains($0.day) })) {
            if let added = meters.removeValue(forKey: row.dayKey) { row.meters += added }
        }
        for (day, value) in meters {
            context.insert(WalkedDay(day: day, meters: value))
        }
        return .merged(days)
    }

    /// The backfill's clamp (eng A1): each day mask ANDed with its block's
    /// saved mask, so no day row claims a tenth the totals do not, and the
    /// totals stay byte for byte what they were. A day left with no bits
    /// keeps its distance.
    func clampedToSavedMasks(
        _ days: [WalkedDayKey: BlockMatcher.DayDelta],
        in context: ModelContext
    ) throws -> [WalkedDayKey: BlockMatcher.DayDelta] {
        var saved: [UInt32: UInt16] = [:]
        for block in try context.fetch(FetchDescriptor<WalkedBlock>()) {
            saved[block.physicalID] = block.mask
        }
        return days.mapValues { delta in
            var clamped = delta
            clamped.masks = [:]
            for (physicalID, mask) in delta.masks {
                let kept = mask & (saved[physicalID] ?? 0)
                if kept != 0 { clamped.masks[physicalID] = kept }
            }
            return clamped
        }
    }

    /// Mirrors a saved pass's day rows in memory. A rebuild or backfill
    /// replaces them (and the estimate); an incremental pass merges its
    /// delta. `historyVersion` advances when anything changed.
    func didSave(_ write: DayWrite, estimatedThroughDay: WalkedDayKey?) {
        switch write {
        case .replaced(let all):
            days = WalkedDayRows(all, estimatedThroughDay: estimatedThroughDay)
            isDayIndexCurrent = true
        case .merged(let delta):
            guard !delta.isEmpty else { return }
            days?.merge(delta)
        }
        historyVersion += 1
        cachedHistory = nil
    }

    /// Clear History: no day rows, and the index counts as current (an
    /// empty store has nothing to backfill).
    func clearDays() {
        days = WalkedDayRows()
        isDayIndexCurrent = true
        historyVersion += 1
        cachedHistory = nil
    }

    /// Your Walks' history, or `nil` while the day rows are not at
    /// `dayIndexVersion` (a backfill that failed, eng A6). Reads every day
    /// row once, then stays current from each pass in memory.
    func history() throws -> WalkedHistory? {
        if let cachedHistory { return cachedHistory }
        if days == nil {
            guard let loaded = try loadDays() else { return nil }
            days = loaded
            historyVersion += 1
        }
        guard isDayIndexCurrent == true, let days else { return nil }
        let built = WalkedHistory.build(
            dayMasks: days.masks,
            dayMeters: days.meters,
            grid: grid,
            estimatedThroughDay: days.estimatedThroughDay,
            version: historyVersion
        )
        cachedHistory = built
        return built
    }

    /// The walked runs of one day, for its map (eng A5).
    func dayRuns(_ day: WalkedDayKey) throws -> [WalkedRun] {
        guard let summary = try history()?.summary(for: day) else { return [] }
        return WalkedOverlay.runs(walkedIDs: summary.walkedIDs, grid: grid)
    }

    private func loadDays() throws -> WalkedDayRows? {
        let context = Self.makeContext(container)
        guard let state = try context.fetch(FetchDescriptor<WalkedMatchState>()).first else {
            // Nothing matched yet, or just cleared: no rows to read.
            isDayIndexCurrent = true
            return WalkedDayRows()
        }
        guard state.dayIndexVersion == Self.dayIndexVersion else {
            isDayIndexCurrent = false
            return nil
        }
        isDayIndexCurrent = true
        var rows = WalkedDayRows(estimatedThroughDay: state.estimatedThroughDay.map(WalkedDayKey.init(value:)))
        for row in try context.fetch(FetchDescriptor<WalkedDayBlock>()) {
            rows.masks[row.dayKey, default: [:]][row.physicalID] = row.mask
        }
        for day in try context.fetch(FetchDescriptor<WalkedDay>()) {
            rows.meters[day.dayKey] = day.meters
        }
        return rows
    }
}
