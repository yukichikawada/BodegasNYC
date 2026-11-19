import SwiftUI
import UIKit

/// Your Walks (#170 PR 1, design DS1 to DS8): the days you walked, as one
/// vertical scroll of months opened at the current one, and a day pushed
/// from a dot as its map and counts.
///
/// `NavigationStack`, inline title, Done, `.large` only, opaque
/// `systemGroupedBackground`, bare ground with no card around the grid
/// (DS8.4). A Calendar / Progress switch sits under the title, opening on
/// Calendar (PR 2, DS6; Progress is `WalkProgressView`). A tap on the title
/// scrolls to the current month (DS2), and
/// VoiceOver gets the same as a "Show This Month" action on the heading.
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
    @State private var tab = Tab.calendar
    /// Kept across tab switches while the sheet is open; opens on 1 month.
    @State private var range = WalkProgressRange.initial
    /// The Share a Walk form is up (#177).
    @State private var isSharing = false
    /// A share completed from the form; its dismissal returns focus here.
    @State private var didShare = false
    @AccessibilityFocusState private var isShareEntryFocused: Bool

    enum Tab: Hashable { case calendar, progress }

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
                            // The tap's VoiceOver equivalent (DS2).
                            .accessibilityAction(named: AppCopy.YourWalks.showThisMonth.copy.text) {
                                scrollToCurrentMonth += 1
                            }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppCopy.doneAction.copy.text) { dismiss() }
                    }
                    // Share a Walk (#177 DS4), on both tabs; hidden while
                    // the history loads or has no walked day.
                    if content.phase == .ready, !content.walkedDays.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            ShareWalkEntryButton(focus: $isShareEntryFocused) { isSharing = true }
                        }
                    }
                }
                .navigationDestination(for: WalkedDayKey.self) { day in
                    WalkDayView(day: day, viewModel: viewModel)
                }
        }
        .sheet(isPresented: $isSharing, onDismiss: shareFormDidDismiss) {
            // Opened from Your Walks: the most recent walked day (eng E4).
            if let latest = viewModel.walksHistory?.walkedDays.last?.day {
                ShareWalkSheet(viewModel: viewModel, preset: latest) { didShare = true }
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

    /// After a completed share, VoiceOver goes back to the entry button
    /// (#177 design Accessibility).
    private func shareFormDidDismiss() {
        guard didShare else { return }
        didShare = false
        isShareEntryFocused = true
    }

    /// The Calendar / Progress switch under the title (PR 2, DS6), opening
    /// on Calendar, then the chosen tab. The states with no grid show the
    /// same lines on both tabs.
    private func calendarOrProgress(_ content: YourWalksContent) -> some View {
        VStack(spacing: 0) {
            Picker(AppCopy.YourWalks.tabPicker.copy.text, selection: $tab) {
                Text(AppCopy.YourWalks.calendarTab.copy.text).tag(Tab.calendar)
                Text(AppCopy.YourWalks.progressTab.copy.text).tag(Tab.progress)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Group {
                if !content.showsGrid {
                    stateList(content)
                } else if tab == .calendar {
                    WalkCalendarView(content: content, scrollToCurrentMonth: scrollToCurrentMonth)
                } else {
                    WalkProgressView(content: content, progress: viewModel.walkProgress(), range: $range)
                }
            }
            .frame(maxHeight: .infinity)
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

/// "Finding your walks…" or "No blocks counted yet." under the title
/// (DS8.2), on both tabs.
struct YourWalksStatusLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
    }
}
