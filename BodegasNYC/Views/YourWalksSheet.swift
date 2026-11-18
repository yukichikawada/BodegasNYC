import SwiftUI
import UIKit

/// Your Walks (#170 PR 1, design DS1 to DS8): the days you walked, as one
/// vertical scroll of months opened at the current one, and a day pushed
/// from a dot as its map and counts.
///
/// `NavigationStack`, inline title, Done, `.large` only, opaque
/// `systemGroupedBackground`, bare ground with no card around the grid
/// (DS8.4). PR 1 ships the Calendar alone; PR 2 adds the Calendar/Progress
/// switch under the title (`calendarOrProgress` is the one slot it
/// replaces). A tap on the title scrolls to the current month (DS2).
///
/// States (DS8.2), failure > loading > empty: the street data failing, or
/// the day rows failing (eng A6), shows one `.primary` line and no grid; a
/// first read shows this month's grid with muted numbers and "Finding your
/// walks…" under the title from 0 s; a refresh keeps the last result; no
/// history shows the no-streets copy with the recording lines; history with
/// no walked day shows the grid and "No blocks counted yet.". Clear History
/// with a day open pops back to the calendar (DS8.3).
struct YourWalksSheet: View {
    let viewModel: StreetsWalkedViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var path: [WalkedDayKey] = []
    /// Bumped by a title tap; the calendar scrolls to the current month.
    @State private var scrollToCurrentMonth = 0

    var body: some View {
        let content = viewModel.yourWalks()
        NavigationStack(path: $path) {
            calendarOrProgress(content)
                .background(Color(.systemGroupedBackground))
                .navigationTitle(AppCopy.YourWalks.title.copy.text)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(AppCopy.YourWalks.title.copy.text)
                            .font(.headline)
                            .lineLimit(1)
                            .onTapGesture { scrollToCurrentMonth += 1 }
                            .accessibilityAddTraits(.isHeader)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppCopy.doneAction.copy.text) { dismiss() }
                    }
                }
                .navigationDestination(for: WalkedDayKey.self) { day in
                    WalkDayView(day: day, viewModel: viewModel)
                }
        }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemGroupedBackground))
        .onAppear { viewModel.yourWalksDidOpen() }
        .onDisappear { viewModel.yourWalksDidClose() }
        .onChange(of: content.walkedDays) { _, walked in
            // Clear History emptied the open day (DS8.3).
            path.removeAll { !walked.contains($0) }
        }
    }

    /// The Calendar (PR 1). PR 2's switch chooses between this and Progress.
    @ViewBuilder
    private func calendarOrProgress(_ content: YourWalksContent) -> some View {
        if content.showsGrid {
            WalkCalendarView(content: content, scrollToCurrentMonth: scrollToCurrentMonth)
        } else {
            stateList(content)
        }
    }

    /// The states with no grid (DS8.2): a failure line, or no history.
    private func stateList(_ content: YourWalksContent) -> some View {
        List {
            Section {
                switch content.phase {
                case .streetMapUnavailable:
                    Text(AppCopy.YourBlocks.streetMapUnavailable.copy.text)
                        .foregroundStyle(.primary)
                case .historyFailed:
                    Text(AppCopy.YourWalks.historyFailed.copy.text)
                        .foregroundStyle(.primary)
                default:
                    // The section empty state (DD9): title over body, muted.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppCopy.emptyNoStreetsTitle.copy.text)
                            .font(.subheadline)
                        Text(AppCopy.emptyNoStreetsBody.copy.text)
                            .font(.footnote)
                    }
                    .foregroundStyle(Color.textMuted)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppCopy.YourWalks.footer.copy.text)
                    if content.phase == .noHistory, content.isRecordingOff {
                        Text(AppCopy.YourBlocks.recordingOff.copy.text)
                    }
                    if content.phase == .noHistory, content.pausedProblem != nil {
                        Text(AppCopy.YourBlocks.recordingPaused.copy.text)
                    }
                }
            }
            if content.phase == .noHistory, content.showsPausedSettingsRow {
                Section {
                    Button(AppCopy.YourBlocks.openSettings.copy.text) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
