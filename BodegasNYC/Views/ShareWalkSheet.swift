import SwiftUI

/// Share a Walk (#177 PR 1, design DS4): pick days, see exactly the picture
/// that goes, and hand it to the system share sheet.
///
/// `.large` only, opaque `systemGroupedBackground`, `NavigationStack`,
/// inline title "Share a Walk", Cancel leading. One scroll: the picture
/// (4:5, 12 pt radius, on `secondarySystemBackground`), the From and To
/// rows in an inset-grouped section with the definition line under them,
/// the three consequence lines in `.subheadline` `.primary`, then Share,
/// `.borderedProminent` and full width, pinned in a bottom `safeAreaInset`
/// on the same ground, or at the end of the scroll when the pinned bar
/// would leave under 200 pt to read (the intro sheet's rule).
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
                List {
                    if let form {
                        content(form)
                        if !pinsBar {
                            Section { shareBar(form) }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if pinsBar, let form {
                        shareBar(form)
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
            guard let history = viewModel.walksHistory, form?.historyChanged(history) == true else {
                dismiss()
                return
            }
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

    @ViewBuilder
    private func content(_ form: ShareWalkForm) -> some View {
        Section {
            ShareWalkPicturePanel(form: form) { self.form?.retry() }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        Section {
            dateRow(.fromLabel, day: form.start, range: form.firstDay ... form.today, id: "shareWalk.from") {
                self.form?.setFrom($0)
            }
            dateRow(.toLabel, day: form.end, range: form.start ... form.today, id: "shareWalk.to") {
                self.form?.setTo($0)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppCopy.ShareWalk.definition.copy.text)
                if form.walk.isEstimate {
                    Text(AppCopy.ShareWalk.estimate.copy.text)
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.textMuted)
        }
        Section {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.consequences, id: \.self) {
                    Text($0.copy.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    /// A compact date row in New York walk days; label over picker at
    /// accessibility sizes.
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
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.copy.text)
                picker.labelsHidden()
            }
        } else {
            picker
        }
    }

    /// The reason line directly above a disabled Share (in the focus order
    /// before it, and its VoiceOver hint too), then Share, on the form's
    /// opaque ground. A failure's line is in the picture's place instead.
    private func shareBar(_ form: ShareWalkForm) -> some View {
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
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

    /// The share sheet closed: a completed share is recorded and closes the
    /// form; a cancel keeps it.
    private func shareFinished(completed: Bool) {
        guard completed else {
            isShareFocused = true
            return
        }
        viewModel.walkShared()
        onShared()
        dismiss()
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
