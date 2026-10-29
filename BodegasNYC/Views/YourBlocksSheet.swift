import SwiftUI
import UIKit

/// Your Blocks (#108 PR 2, design D7, D8, D6, D11): walked blocks out of
/// every street block, citywide and per borough. The sheet is the
/// accessible equivalent of the overlay.
///
/// Inset-grouped `List`, inline title, Done; `.medium` and `.large`, `.large`
/// only at the accessibility sizes (the `BodegaFilterSheet` precedent).
/// Section 1 is New York City, section 2 the five boroughs in
/// `Borough.displayOrder`. A row is the name (`.body`) over the count
/// (`.subheadline` `textMuted`) with the percent trailing, monospaced
/// digits; it stacks at the accessibility sizes and otherwise uses
/// `ViewThatFits` (the `BodegaRow` idiom). No progress bars, no display
/// register. Opaque (`systemGroupedBackground`) at both detents, since the
/// counts are `textMuted`.
///
/// States (D8), failure > counting > zero: the street data failing, or a
/// first count failing twice (#113), replaces both sections with one
/// `.primary` line; a first count shows "—" and,
/// 0.5s in, "Counting your blocks…"; a recount keeps the last counts; zero
/// adds "Walk somewhere. This fills in on its own." (not while paused). The
/// footer adds "Recording is off." or "Recording is paused." and the Motion
/// denial line when they apply; paused for something Settings fixes adds an
/// Open Settings row (#123 design DS3).
struct YourBlocksSheet: View {
    let viewModel: StreetsWalkedViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    /// "Counting your blocks…" waits 0.5s, so a quick count never flashes it.
    @State private var showsCountingStatus = false

    static let countingStatusDelay: Duration = .milliseconds(500)

    var body: some View {
        let content = viewModel.yourBlocks
        NavigationStack {
            List {
                if let failure = Self.failureLine(content.phase) {
                    Section {
                        Text(failure.copy.text)
                            .foregroundStyle(.primary)
                    } footer: {
                        footer(content)
                    }
                } else {
                    Section {
                        YourBlocksRow(row: content.citywide)
                    } footer: {
                        citywideFooter(content)
                    }
                    Section {
                        ForEach(content.boroughs) { YourBlocksRow(row: $0) }
                    } footer: {
                        footer(content)
                    }
                }
                if content.showsPausedSettingsRow {
                    Section {
                        Button(AppCopy.YourBlocks.openSettings.copy.text) { openSettings() }
                    }
                }
                motionSection(content.motionRow)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppCopy.YourBlocks.title.copy.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppCopy.doneAction.copy.text) { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        // Opaque at every detent: the counts are `textMuted` data lines, which
        // DESIGN.md allows on opaque surfaces only; iOS 26 draws a `.medium`
        // sheet as glass by default.
        .presentationBackground(Color(.systemGroupedBackground))
        .task(id: content.phase == .counting) {
            guard content.phase == .counting else {
                showsCountingStatus = false
                return
            }
            try? await Task.sleep(for: Self.countingStatusDelay)
            if !Task.isCancelled { showsCountingStatus = true }
        }
        .onAppear { viewModel.yourBlocksDidOpen() }
    }

    /// The one line that replaces both sections when counts can't show.
    static func failureLine(_ phase: YourBlocksContent.Phase) -> AppCopy.YourBlocks? {
        switch phase {
        case .unavailable: .streetMapUnavailable
        case .countFailed: .countFailed
        case .counting, .zero, .counted: nil
        }
    }

    @ViewBuilder
    private func citywideFooter(_ content: YourBlocksContent) -> some View {
        switch content.phase {
        case .counting where showsCountingStatus:
            Text(AppCopy.YourBlocks.countingStatus.withTrailingEllipsis)
        case .zero where content.showsZeroLine:
            Text(AppCopy.emptyNoStreetsBody.copy.text)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func motionSection(_ row: YourBlocksContent.MotionRow) -> some View {
        switch row {
        case .hidden:
            EmptyView()
        case .allowAccess:
            Section {
                Button(AppCopy.YourBlocks.allowMotionAccess.copy.text) {
                    Task { await viewModel.requestMotionAccess() }
                }
            }
        case .openSettings:
            Section {
                Button(AppCopy.YourBlocks.openSettings.copy.text) { openSettings() }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func footer(_ content: YourBlocksContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.YourBlocks.footer.copy.text)
            if content.isRecordingOff {
                Text(AppCopy.YourBlocks.recordingOff.copy.text)
            }
            if content.pausedProblem != nil {
                Text(AppCopy.YourBlocks.recordingPaused.copy.text)
            }
            if content.isMotionDenied {
                Text(AppCopy.YourBlocks.motionDenied.copy.text)
            }
        }
    }
}

/// One place's row: name over count, percent trailing; stacked at the
/// accessibility sizes. One VoiceOver element (design D11).
private struct YourBlocksRow: View {
    let row: YourBlocksContent.Row
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        layout
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityIdentifier("yourBlocks.row.\(row.id)")
    }

    @ViewBuilder
    private var layout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        }
    }

    private var sideBySide: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                name
                count
            }
            Spacer(minLength: 0)
            percent
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            name
            count
            percent
        }
    }

    private var name: some View {
        Text(row.name)
            .font(.body)
    }

    /// "412 of 9,300 blocks"; the city's "412 blocks" with "of 99,360" in
    /// `textMuted`; "—" while counting.
    private var count: some View {
        countText
            .font(.subheadline)
            .monospacedDigit()
    }

    private var countText: Text {
        guard let walked = row.walked, let total = row.total else {
            return Text(AppCopy.countingPlaceholder).foregroundStyle(Color.textMuted)
        }
        guard row.borough == nil else {
            return Text(AppCopy.boroughBlockCount(walked: walked, total: total).text).foregroundStyle(Color.textMuted)
        }
        let parts = AppCopy.citywideBlockCountParts(walked: walked, total: total)
        let walkedText = Text(parts.walked).foregroundStyle(.primary)
        return Text("\(walkedText) \(Text(parts.total).foregroundStyle(Color.textMuted))")
    }

    private var percent: some View {
        Text(row.percentText)
            .font(.body)
            .monospacedDigit()
    }
}
