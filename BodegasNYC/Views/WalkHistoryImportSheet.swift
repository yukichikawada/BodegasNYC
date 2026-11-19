import SwiftUI

/// The Import History sheet (#180 PR 2, design D1 to D6, D9, DS1, DS4,
/// D14), on the Account sheet's pattern: inset-grouped `Form`, inline
/// title, `.medium` and `.large` (`.large` only at accessibility sizes), the
/// opaque grouped ground, one state enum (`HistoryImportPhase`, on the
/// shared view model so every window agrees, eng A4) and 0.25 s opacity
/// swaps. Saving hides every control and blocks swipe-down and escape.
struct WalkHistoryImportSheet: View {
    let viewModel: StreetsWalkedViewModel
    /// The window this sheet is in; the session must be its own.
    let owner: StreetsWalkedViewModel.SceneToken
    let onShowYourWalks: () -> Void
    let onStartRecording: () -> Void
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState var focus: Focus?
    /// The last phase shown, kept while the sheet animates out.
    @State var shownPhase = HistoryImportPhase.reading
    @State private var showsReadingRow = false
    @State var barHeight: CGFloat = 0

    typealias Copy = AppCopy.HistoryImport

    enum Focus: Hashable {
        case reading
        case heading
        case failure
        case terminal
    }

    var session: HistoryImportSession? {
        guard let session = viewModel.historyImport, session.owner == owner else { return nil }
        return session
    }

    var phase: HistoryImportPhase { session?.phase ?? shownPhase }
    var isSaving: Bool { phase == .saving }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let pinsBar = StreetsWalkedIntro.pinsButtonBar(availableHeight: proxy.size.height, barHeight: barHeight)
                Form {
                    content
                    if !pinsBar, hasBar {
                        Section { bar }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if pinsBar, hasBar { bar.background(Color(.systemGroupedBackground)) }
                }
            }
            .disabled(isSaving)
            .animation(AccountView.swapAnimation, value: phase)
            .navigationTitle(Copy.menuItem.copy.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
        .interactiveDismissDisabled(isSaving)
        // Escape is Cancel before saving and nothing while saving (D14).
        .accessibilityAction(.escape) {
            if !isSaving { dismiss() }
        }
        .onAppear { phaseChanged(to: phase, replaced: false) }
        .onChange(of: session?.phase) { _, newPhase in
            guard let newPhase else { return }
            phaseChanged(to: newPhase, replaced: false)
        }
        .onChange(of: session?.replacements) { old, new in
            guard let old, let new, new > old else { return }
            phaseChanged(to: .reading, replaced: true)
        }
        // "Reading the file…" only from 0.5 s, and its announcement with it.
        .task(id: session?.request) {
            showsReadingRow = false
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil, phase == .reading else { return }
            showsReadingRow = true
            // A replaced file already said "Another file opened." (D9).
            if session?.replacements == 0 {
                AccessibilityNotification.Announcement(Copy.readingAnnouncement.copy.text).post()
            }
        }
        .onDisappear { viewModel.endHistoryImport(owner: owner) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading:
            Section {
                if showsReadingRow {
                    spinnerRow(Copy.reading.withTrailingEllipsis)
                        .accessibilityFocused($focus, equals: .reading)
                } else {
                    Color.clear.frame(minHeight: 44).accessibilityHidden(true)
                }
            }
        case .preview(let preview, _):
            previewSections(preview)
        case .nothingNew(let hasSkipped):
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.nothingNewTitle.copy.text)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.nothingNewBody.copy.text)
                    if hasSkipped { Text(Copy.skippedEntries.copy.text) }
                }
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityFocused($focus, equals: .terminal)
            }
        case .message(let message):
            Section { terminalLine(message.copy.text) }
        case .saving:
            Section { spinnerRow(Copy.saving.withTrailingEllipsis) }
        case .counting:
            Section { spinnerRow(AppCopy.YourBlocks.countingStatus.withTrailingEllipsis) }
        case .done:
            Section {
                terminalLine(Copy.done.copy.text)
                if viewModel.recordingState == .off {
                    Text(Copy.recordingOff.copy.text)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// DS1, D2, D3: heading, file name, dates, days, then the lines that
    /// apply, the consequence and the known limit (eng A11) as the footer.
    @ViewBuilder
    private func previewSections(_ preview: WalkHistoryTransfer.ImportPreview) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.heading.copy.text)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focus, equals: .heading)
                Text(preview.fileName)
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
                if let first = preview.firstDay, let last = preview.lastDay {
                    Text(AppCopy.sharedWalkDates(first: first, last: last).text)
                        .font(.body)
                        .accessibilityLabel(AppCopy.sharedWalkSpokenDates(first: first, last: last))
                }
                Text(AppCopy.historyImportDays(preview.dayCount).text)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Color.textMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        }
        Section {
            if preview.newFixCount < preview.fileFixCount { line(Copy.partlyHere) }
            if preview.skippedFixCount > 0 { line(Copy.skippedEntries) }
            if preview.newFixesLackEvidence { line(Copy.estimates) }
            Text(Copy.consequence.copy.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Text(Copy.footer.copy.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ copy: Copy) -> some View {
        Text(copy.copy.text)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func terminalLine(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($focus, equals: .terminal)
            .accessibilityIdentifier("historyImport.terminal")
    }

    private func spinnerRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

}

// MARK: - Bar, toolbar, announcements

extension WalkHistoryImportSheet {

    var hasBar: Bool {
        switch phase {
        case .preview, .done: true
        default: false
        }
    }

    /// Add Walks on the preview; Show Your Walks and, with recording off,
    /// Start Recording when done (DS4). Full width, large, wrapping.
    @ViewBuilder
    var bar: some View {
        VStack(spacing: 12) {
            switch phase {
            case .preview(_, let saveFailed):
                Button {
                    Task { await viewModel.commitHistoryImport() }
                } label: {
                    label(Copy.addAction.copy.text)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("historyImport.add")
                if saveFailed {
                    Text(Copy.saveFailure.copy.text)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityFocused($focus, equals: .failure)
                }
            case .done:
                Button(action: onShowYourWalks) {
                    label(Copy.showYourWalks.copy.text)
                }
                .buttonStyle(.borderedProminent)
                if viewModel.recordingState == .off {
                    Button(action: onStartRecording) {
                        label(AppCopy.startRecordingAction.copy.text)
                    }
                    .buttonStyle(.bordered)
                }
            default:
                EmptyView()
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
    }

    func label(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        if phase.isCancellable {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppCopy.cancelAction.copy.text) { dismiss() }
            }
        } else if !isSaving {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppCopy.doneAction.copy.text) { dismiss() }
            }
        }
    }

    // MARK: Announcements and focus (D14)

    /// One announcement or focus move per state change.
    func phaseChanged(to newPhase: HistoryImportPhase, replaced: Bool) {
        shownPhase = newPhase
        switch newPhase {
        case .reading:
            if replaced {
                AccessibilityNotification.Announcement(Copy.replaced.copy.text).post()
                focus = .reading
            }
        case .preview(_, let saveFailed):
            focus = saveFailed ? .failure : .heading
        case .saving:
            AccessibilityNotification.Announcement(Copy.savingAnnouncement.copy.text).post()
        case .counting:
            AccessibilityNotification.Announcement(Copy.countingAnnouncement.copy.text).post()
        case .nothingNew, .message, .done:
            focus = .terminal
        }
    }
}
