import SwiftUI

/// The duplicate prompt (#20): bodegas already on the map within 50 m of the
/// pin, shown as a half sheet over the Add a Bodega form when Submit finds
/// any. Tapping one opens it and drops the draft; "No, It's New" goes ahead
/// with the insert; swiping down returns to the form.
///
/// Design DS1-DS9 on #20: the header is the List's first section so it
/// scrolls with the matches under the pinned button; the matches sit in an
/// inset-grouped panel; title, panel edge and button share the 16pt page
/// inset. System material, list and button only, so dark mode needs nothing.
struct DuplicateBodegaSheet: View {
    let matches: [Bodega]
    let onPick: (Bodega) -> Void
    let onConfirmNew: () -> Void

    @AccessibilityFocusState private var titleIsFocused: Bool

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 12, trailing: 0))
            }
            .listSectionSeparator(.hidden)
            Section {
                ForEach(matches) { bodega in
                    matchRow(bodega)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) { confirmBar }
        .onAppear { titleIsFocused = true }
    }

    /// Title, body and footnote at 4pt, footnote 12pt above the panel (DS7).
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppCopy.duplicatePromptTitle.copy.text)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleIsFocused)
            Text(AppCopy.duplicatePromptBody.copy.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(AppCopy.duplicatePromptFootnote.copy.text)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The List tab's row plus a chevron; names are never tinted (DS1). The
    /// chevron is decoration, so VoiceOver reads one button: name, address,
    /// and the footnote as its hint (DS3, DS9).
    private func matchRow(_ bodega: Bodega) -> some View {
        Button {
            onPick(bodega)
        } label: {
            HStack {
                BodegaRow(bodega: bodega)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityHint(AppCopy.duplicatePromptFootnote.copy.text)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    /// Pinned under the list; the material frosts rows scrolling beneath it
    /// on a long list (DS4). `.bordered`, not prominent: the rows carry the
    /// affordance.
    private var confirmBar: some View {
        Button {
            onConfirmNew()
        } label: {
            Text(AppCopy.duplicateConfirmNewAction.copy.text)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}
