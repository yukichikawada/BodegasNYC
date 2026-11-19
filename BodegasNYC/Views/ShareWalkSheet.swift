import SwiftUI

/// Share a Walk (#177 PR 1, design DS4): pick days, see exactly the picture
/// that goes, and hand it to the system share sheet.
///
/// `.large` only, opaque `systemGroupedBackground`, `NavigationStack`,
/// inline title "Share a Walk", Cancel leading. One scroll on one 16 pt page
/// inset: the picture (4:5, 12 pt radius, on `secondarySystemBackground`;
/// gone with no blocks or too many), the From and To rows in an
/// inset-grouped panel, the definition and estimate lines under it, the
/// three consequence lines in `.subheadline` `.primary`, then the reason
/// line and Share, `.borderedProminent` and full width, pinned in a bottom
/// `safeAreaInset` on the same ground, or at the end of the scroll when the
/// pinned bar would leave under 200 pt to read (the intro sheet's rule).
///
/// The preview is the picture itself (DS4), made 0.3 s after the last date
/// change; Share sends that same image, and is disabled whenever the
/// picture on show is not the current dates' (`ShareWalkForm`). A completed
/// share closes the form; a cancelled one leaves it as it was. Clear
/// History while it is open closes it.
struct ShareWalkSheet: View {
    let viewModel: StreetsWalkedViewModel
    /// A share completed; the presenter returns focus to its entry button
    /// once the form is gone.
    let onShared: () -> Void
    @State private var form: ShareWalkForm?
    /// VoiceOver on Share: back here after a cancelled share sheet, and the
    /// one place a ready picture is announced.
    @AccessibilityFocusState private var isShareFocused: Bool
    /// The picture handed to the share sheet while it is up.
    @State private var sharing: SharedWalkPicture?
    @State private var barHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The three consequence lines, in order (DS4, DS7).
    static let consequences: [AppCopy.ShareWalk] = [.consequenceWhatGoes, .consequenceStartAndEnd, .consequencePassedOn]

    /// The wait after the last date change before a picture is made.
    static let debounce: Duration = .milliseconds(300)
    /// The page inset every block of the form shares (DESIGN.md Layout).
    static let pageInset: CGFloat = 16

    init(
        viewModel: StreetsWalkedViewModel,
        preset: WalkedDayKey,
        today: WalkedDayKey = WalkedDayKey(date: Date()),
        onShared: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onShared = onShared
        _form = State(initialValue: viewModel.walksHistory.flatMap {
            ShareWalkForm(history: $0, preset: preset, today: today)
        })
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let pinsBar = StreetsWalkedIntro.pinsButtonBar(
                    availableHeight: proxy.size.height,
                    barHeight: barHeight
                )
                ScrollView {
                    if let form {
                        VStack(alignment: .leading, spacing: 0) {
                            content(form)
                            if !pinsBar {
                                shareControls(form)
                                    .padding(.top, 24)
                            }
                        }
                        .padding(.horizontal, Self.pageInset)
                        .padding(.vertical, 16)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(Color(.systemGroupedBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if pinsBar, let form {
                        shareControls(form)
                            .padding(.horizontal, Self.pageInset)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity)
                            .background(Color(.systemGroupedBackground))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    }
                }
            }
            .navigationTitle(AppCopy.ShareWalk.title.copy.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppCopy.cancelAction.copy.text) { dismiss() }
                }
            }
        }
        .accessibilityAction(.escape) { dismiss() }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemGroupedBackground))
        .background(ShareSheetPresenter(picture: $sharing, onFinish: shareFinished))
        .task(id: RenderKey(request: form?.request, attempt: form?.attempt ?? 0)) {
            await makePicture()
        }
        .onChange(of: viewModel.walksHistory?.version) { _, _ in
            if form?.historyChanged(viewModel.walksHistory) != true { dismiss() }
        }
        .onChange(of: form?.phase) { old, new in
            announce(from: old, to: new)
        }
        .onAppear {
            if form == nil { dismiss() }
        }
    }

    /// What the picture task depends on: the request and Retry's count.
    private struct RenderKey: Hashable {
        let request: ShareWalkForm.Request?
        let attempt: Int
    }

    /// The picture (only while there is one to make or show), the dates,
    /// the definition and estimate lines, and the consequence lines, all on
    /// the page inset.
    @ViewBuilder
    private func content(_ form: ShareWalkForm) -> some View {
        if form.showsPicturePanel {
            ShareWalkPicturePanel(form: form) { self.form?.retry() }
                .padding(.bottom, 24)
        }
        VStack(spacing: 0) {
            dateRow(.fromLabel, day: form.start, range: form.firstDay ... form.today, id: "shareWalk.from") {
                self.form?.setFrom($0)
            }
            Divider().padding(.leading, Self.pageInset)
            dateRow(.toLabel, day: form.end, range: form.start ... form.today, id: "shareWalk.to") {
                self.form?.setTo($0)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 4) {
            Text(AppCopy.ShareWalk.definition.copy.text)
            if form.walk.isEstimate {
                Text(AppCopy.ShareWalk.estimate.copy.text)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.textMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.consequences, id: \.self) {
                Text($0.copy.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    /// A compact date row in New York walk days, at the grouped row's own
    /// 16 pt inset and 44 pt height; label over picker at accessibility
    /// sizes.
    @ViewBuilder
    private func dateRow(
        _ label: AppCopy.ShareWalk,
        day: WalkedDayKey,
        range: ClosedRange<WalkedDayKey>,
        id: String,
        set: @escaping (WalkedDayKey) -> Void
    ) -> some View {
        let selection = Binding<Date>(get: { day.noon }, set: { set(WalkedDayKey(calendarDate: $0)) })
        let dates = range.lowerBound.noon ... range.upperBound.noon
        let picker = DatePicker(selection: selection, in: dates, displayedComponents: .date) {
            Text(label.copy.text)
        }
        .environment(\.timeZone, WalkedDayKey.timeZone)
        .environment(\.calendar, WalkedDayKey.calendar)
        .accessibilityIdentifier(id)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label.copy.text)
                    picker.labelsHidden()
                }
            } else {
                picker
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, Self.pageInset)
        .padding(.vertical, 6)
    }

    /// The reason line directly above a disabled Share (in the focus order
    /// before it, and its VoiceOver hint too), then Share. A failure's line
    /// is in the picture's place instead.
    private func shareControls(_ form: ShareWalkForm) -> some View {
        let reason = form.disabledReason
        return VStack(alignment: .leading, spacing: 8) {
            if let reason, reason != .pictureFailed {
                Text(reason.copy.text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shareWalk.reason")
            }
            Button {
                sharing = form.shareablePicture
            } label: {
                Text(AppCopy.ShareWalk.shareAction.copy.text)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!form.canShare)
            .accessibilityHint(reason?.copy.text ?? "")
            .accessibilityIdentifier("shareWalk.share")
            .accessibilityFocused($isShareFocused)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Makes the picture for the current request, 0.3 s after the last
    /// change (a newer request cancels this one first).
    private func makePicture() async {
        guard let form, form.phase == .making else { return }
        let request = form.request
        let walk = form.walk
        try? await Task.sleep(for: Self.debounce)
        guard !Task.isCancelled else { return }
        let runs = await viewModel.shareRuns(walk)
        guard !Task.isCancelled else { return }
        let snapshotter = StreetsWalkedViewModel.walkSnapshotter
        let result = await SharedWalkCard.make(walk: walk, runs: runs, snapshotter: snapshotter)
        guard !Task.isCancelled else { return }
        // The picture's 0.25 s opacity swap, the same under Reduce Motion.
        withAnimation(.easeInOut(duration: 0.25)) {
            self.form?.pictureMade(result, for: request)
        }
    }

    /// The share sheet closed (`ShareWalkForm.shareFinished`): a completed
    /// share is recorded, reported and closes the form; a cancel keeps it,
    /// with VoiceOver back on Share.
    private func shareFinished(completed: Bool) {
        switch ShareWalkForm.shareFinished(completed: completed, record: viewModel.walkShared) {
        case .closeForm:
            onShared()
            dismiss()
        case .stayOnShare:
            isShareFocused = true
        }
    }

    /// A failure, and Share turning disabled for a reason, are announced
    /// with that reason. A ready picture is announced only when it ends a
    /// making state while VoiceOver is on Share; otherwise a new picture on
    /// a date change is not announced.
    private func announce(from old: ShareWalkForm.Phase?, to new: ShareWalkForm.Phase?) {
        guard let old, let new, old != new else { return }
        let text: String? = switch new {
        case .failed: AppCopy.ShareWalk.pictureFailed.copy.text
        case .noBlocks: AppCopy.ShareWalk.noBlocks.copy.text
        case .tooManyBlocks: AppCopy.ShareWalk.tooManyBlocks.copy.text
        // Share was disabled while the picture was made, and VoiceOver is
        // waiting on it: say the picture (its dates and counts) is in.
        case .ready:
            old == .making && isShareFocused
                ? form?.shareablePicture.map { AppCopy.sharedWalkPictureValue($0.walk).text }
                : nil
        case .making: nil
        }
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}
