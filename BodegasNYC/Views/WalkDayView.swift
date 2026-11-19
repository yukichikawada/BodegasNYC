import MapKit
import SwiftUI

/// One walked day (#170 design DS4, DS5, DS7, DS8.4): its map and, in a
/// bottom bar on the opaque ground, "14 blocks" with "9 new" in `textMuted`
/// over "1.4 miles". Title "Nov 3, 2025", inline.
///
/// The map is `WalkRunsMap` (#177: level, north-up, fitted to the day's
/// runs, the shared trail, the run cap, its VoiceOver actions). It keeps a
/// 200 pt minimum height; when the bar leaves less than that (landscape,
/// large type) the page scrolls. VoiceOver reads the map as one element,
/// "Map of this day's walk.", with the counts as its value.
///
/// Share a Walk (#177 DS4) sits trailing in the bar, opening the form on
/// this day; it hides while the history has no walked day.
struct WalkDayView: View {
    let day: WalkedDayKey
    let viewModel: StreetsWalkedViewModel
    @State private var runs: [WalkedRun]?
    @State private var position: MapCameraPosition = .automatic
    @State private var barHeight: CGFloat = 0
    @State private var isSharing = false
    /// A share completed from the form; its dismissal returns focus here.
    @State private var didShare = false
    @AccessibilityFocusState private var isEntryFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let minimumMapHeight: CGFloat = 200

    var body: some View {
        let summary = viewModel.walksHistory?.summary(for: day)
        let isEstimate = viewModel.walksHistory?.isEstimate(day) ?? false
        GeometryReader { geometry in
            let roomForMap = geometry.size.height - barHeight
            ScrollView {
                VStack(spacing: 0) {
                    WalkRunsMap(
                        runs: runs,
                        position: $position,
                        accessibilityLabel: AppCopy.YourWalks.dayMapLabel.copy.text,
                        accessibilityValue: summary.map { AppCopy.walkDaySummary($0).text } ?? ""
                    )
                    .frame(height: max(Self.minimumMapHeight, roomForMap))
                    summaryBar(summary, isEstimate: isEstimate)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                }
            }
            .scrollDisabled(roomForMap >= Self.minimumMapHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(AppCopy.walkDayTitle(day).text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if summary?.isWalked == true {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareWalkEntryButton(focus: $isEntryFocused) { isSharing = true }
                }
            }
        }
        .sheet(isPresented: $isSharing, onDismiss: shareFormDidDismiss) {
            ShareWalkSheet(viewModel: viewModel, preset: day) { didShare = true }
        }
        // Keyed on the history's version too, so a pass that adds to this
        // day while it is open redraws the trail with the counts. Only the
        // first load fits the camera (`WalkRunsMap`); a reload keeps where
        // the person panned.
        .task(id: RunsKey(day: day, version: viewModel.walksHistory?.version)) {
            runs = await viewModel.walkDayRuns(day)
        }
    }

    /// After a completed share, VoiceOver goes back to the entry button
    /// (#177 design Accessibility).
    private func shareFormDidDismiss() {
        guard didShare else { return }
        didShare = false
        isEntryFocused = true
    }

    /// What the runs depend on: the day and the history they came from.
    private struct RunsKey: Hashable {
        let day: WalkedDayKey
        let version: Int?
    }

    /// Two lines (DS4), stacking at accessibility sizes, and the estimate
    /// line on an estimated day (DS5).
    private func summaryBar(_ summary: WalkedDaySummary?, isEstimate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                layout {
                    Text(AppCopy.walkDayBlocks(summary.walkedIDs.count).text)
                        .foregroundStyle(.primary)
                    if summary.newCount > 0 {
                        Text(AppCopy.walkDayNew(summary.newCount).text)
                            .foregroundStyle(Color.textMuted)
                    }
                }
                .font(.body)
                Text(AppCopy.walkDayDistance(meters: summary.meters).text)
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
            }
            if isEstimate {
                Text(AppCopy.YourWalks.estimates.copy.text)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, 4)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemGroupedBackground))
    }
}

/// The Share a Walk entry (#177 DS4): `square.and.arrow.up` in the label
/// colour on the bar's glass, "Share a Walk" with the hint "Picks days to
/// send." for VoiceOver. `focus` takes VoiceOver back to it after a share.
struct ShareWalkEntryButton: View {
    let focus: AccessibilityFocusState<Bool>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(AppCopy.ShareWalk.title.copy.text)
        .accessibilityHint(AppCopy.ShareWalk.entryHint.copy.text)
        .accessibilityIdentifier("shareWalk.entry")
        .accessibilityFocused(focus)
    }
}
