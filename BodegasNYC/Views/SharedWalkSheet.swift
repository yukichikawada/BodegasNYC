import MapKit
import SwiftUI

/// A walk someone sent you (#177 PR 2, design "Shared Walk sheet (PR 2)").
///
/// `NavigationStack`, inline title "Shared Walk" with the dates as its
/// subtitle, Done, `.large` only, opaque `systemGroupedBackground`. The map
/// is `WalkRunsMap` with the violet solid trail (DS1) and no location dot;
/// under it the day view's bar with the sender's counts from the link
/// ("38 blocks", "6 new to them" in `textMuted`, the distance beneath),
/// then the footnotes: the estimate line, the coverage line, "This walk
/// isn't saved.". The counts show at once; the street data loads from the
/// bundled grid alone (`SharedWalkDrawing`), so nothing is read from or
/// written to the Streets Walked store and no location is asked for.
///
/// States (`SharedWalkScreen`): loading ("Loading the map…" on the map
/// ground), failed (the failure line and Retry, counts kept), offline (the
/// trail on the ground, no failure copy), and the no-map states as Your
/// Walks' state list. A newer link replaces the content in place (the
/// presenter keeps the item's id) and refits the camera.
struct SharedWalkSheet: View {
    let item: SharedWalkInbox.Item
    @State private var drawing = SharedWalkDrawing.loading
    @State private var position: MapCameraPosition = .automatic
    /// Bumped by Retry.
    @State private var attempt = 0
    @State private var barHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let walk = SharedWalkScreen.walk(in: item.result)
        NavigationStack {
            content
                .background(Color(.systemGroupedBackground))
                .navigationTitle(AppCopy.ReceivedWalk.title.copy.text)
                .navigationSubtitle(walk.map(Self.dates) ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppCopy.doneAction.copy.text) { dismiss() }
                    }
                }
        }
        .accessibilityAction(.escape) { dismiss() }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemGroupedBackground))
        .task(id: DrawKey(revision: item.revision, attempt: attempt)) {
            await draw()
        }
        .onAppear {
            // A held sheet: VoiceOver starts again at the top, the title.
            AccessibilityNotification.ScreenChanged(nil).post()
        }
    }

    /// The subtitle: "Nov 3–9, 2026".
    static func dates(_ walk: SharedWalk) -> String {
        AppCopy.sharedWalkDates(first: walk.firstDay, last: walk.lastDay).text
    }

    /// What the drawing depends on: the link (each one refits) and Retry.
    private struct DrawKey: Hashable {
        let revision: Int
        let attempt: Int
    }

    @ViewBuilder
    private var content: some View {
        switch SharedWalkScreen.make(item.result, drawing: drawing) {
        case .walk(let walk, let drawing):
            walkPage(walk, drawing)
        case .message(let line, let offersUpdate):
            messageList(line, offersUpdate: offersUpdate)
        }
    }

    /// The map over the bar, as the day view lays them out: a 200 pt
    /// minimum map, scrolling only when the bar leaves less.
    private func walkPage(_ walk: SharedWalk, _ drawing: SharedWalkDrawing) -> some View {
        GeometryReader { geometry in
            let roomForMap = geometry.size.height - barHeight
            ScrollView {
                VStack(spacing: 0) {
                    map(walk, drawing)
                        .frame(height: max(WalkDayView.minimumMapHeight, roomForMap))
                    summaryBar(walk, drawing)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                }
            }
            .scrollDisabled(roomForMap >= WalkDayView.minimumMapHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func map(_ walk: SharedWalk, _ drawing: SharedWalkDrawing) -> some View {
        var runs: [WalkedRun]?
        if case .ready(let ready, _) = drawing { runs = ready }
        return ZStack {
            WalkRunsMap(
                runs: runs,
                position: $position,
                accessibilityLabel: AppCopy.ReceivedWalk.mapLabel.copy.text,
                accessibilityValue: AppCopy.sharedWalkMapValue(
                    walk,
                    someNotShown: SharedWalkScreen.someNotShown(walk, drawing)
                ).text,
                trail: .shared,
                overCapText: AppCopy.ReceivedWalk.zoomIn.copy.text
            )
            // A newer link: a fresh map, fitted to its runs.
            .id(item.revision)
            switch drawing {
            case .loading:
                Text(AppCopy.ReceivedWalk.loadingMap.withTrailingEllipsis)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            case .failed:
                VStack(spacing: 12) {
                    Text(AppCopy.ReceivedWalk.streetMapFailed.copy.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(AppCopy.retryAction.copy.text) { attempt += 1 }
                        .buttonStyle(.bordered)
                }
                .padding(16)
            case .ready:
                EmptyView()
            }
        }
    }

    /// The day view's bar, byte for byte, with the sender's counts and
    /// "new to them", then the footnotes at 4 pt apart.
    private func summaryBar(_ walk: SharedWalk, _ drawing: SharedWalkDrawing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                Text(AppCopy.walkDayBlocks(walk.blockCount).text)
                    .foregroundStyle(.primary)
                if walk.newCount > 0 {
                    Text(AppCopy.sharedWalkNewToThem(walk.newCount).text)
                        .foregroundStyle(Color.textMuted)
                }
            }
            .font(.body)
            Text(AppCopy.walkDayDistance(meters: Double(walk.meters)).text)
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
            ForEach(SharedWalkScreen.footnotes(walk, drawing), id: \.text) { line in
                Text(line.text)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemGroupedBackground))
    }

    /// No map (Your Walks' state list): the line in `.body` `.primary`,
    /// and for the update states an Update row in the tint.
    private func messageList(_ line: AppCopy.ReceivedWalk, offersUpdate: Bool) -> some View {
        List {
            Section {
                Text(line.copy.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("sharedWalk.message")
            }
            if offersUpdate {
                Section {
                    Button(AppCopy.ReceivedWalk.update.copy.text) { openURL(SharedWalkScreen.appStoreURL) }
                        .foregroundStyle(.tint)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// The runs for the link's walk, from the bundled grid, off the main
    /// actor. Not a walk: nothing to draw.
    private func draw() async {
        guard let walk = SharedWalkScreen.walk(in: item.result) else { return }
        drawing = .loading
        position = .automatic
        drawing = await SharedWalkDrawing.load(walk)
    }
}
