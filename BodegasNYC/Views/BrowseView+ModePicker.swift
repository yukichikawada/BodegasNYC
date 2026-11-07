import SwiftUI

// MARK: - Map/List switch (#44, #143, #160)

extension BrowseView {
    /// UI-test identifiers; exactly one of the two exists at a time.
    static let principalModeSwitchID = "browseMode.principal"
    static let trailingModeSwitchID = "browseMode.trailing"

    /// The Map/List switch in the toolbar's principal slot. A text
    /// segmented control where it fits; from `.xLarge` up, or on phones
    /// narrower than 400 pt, a single-button `Menu` wrapping the same
    /// `Picker` (see `BrowseModePickerStyle`). Wide layouts use
    /// `trailingModeToggle` instead.
    @ViewBuilder
    func modePicker(_ style: BrowseModePickerStyle) -> some View {
        let picker = Picker("Browse Mode", selection: tabSelection) {
            ForEach(Tab.allCases) { tab in
                Label(tab.label, systemImage: tab.systemImage).tag(tab)
            }
        }
        if style == .menu {
            Menu {
                picker
            } label: {
                // The principal slot gives a bare icon (no glass button), so the
                // label carries its own target: 44 pt wide, and as tall as the
                // toolbar allows (it caps items at 36 pt, the same as the
                // system Filters button), so taps near the glyph's edge count.
                Label(activeTab.label, systemImage: activeTab.systemImage)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Browse Mode")
            .accessibilityValue(activeTab.label)
            .accessibilityIdentifier(Self.principalModeSwitchID)
        } else {
            picker
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .frame(maxWidth: 200)
                .accessibilityIdentifier(Self.principalModeSwitchID)
        }
    }

    /// The wide-layout switch (#160 DS1): one glass button in the trailing
    /// group naming the other tab, glyph and text, in the label colour (the
    /// glass default, so no tint). One tap goes there through
    /// `tabSelection`, exactly as the picker does.
    var trailingModeToggle: some View {
        let destination: Tab = activeTab == .map ? .list : .map
        return Button {
            tabSelection.wrappedValue = destination
        } label: {
            // Not a `Label`: the toolbar's glass group drew a `Label` icon-only even with
            // `.labelStyle(.titleAndIcon)` on it (iOS 26.5 simulator, 2026-11-06).
            HStack(spacing: 6) {
                Image(systemName: destination.systemImage)
                Text(destination.label)
            }
        }
        .accessibilityLabel(destination.label)
        .accessibilityIdentifier(Self.trailingModeSwitchID)
        .accessibilityHint(destination == .list ? "Shows the list over the map." : "Returns to the map.")
    }

    /// The switch's trailing item, hosted by `content` between `MapScreenView`
    /// and the Account/Add host, so it merges after Locate Me and Streets
    /// Walked and before Account, and keeps its place on the List tab (#160 DS2).
    @ToolbarContentBuilder
    var trailingModeToolbar: some ToolbarContent {
        if modePickerStyle.isInTrailingGroup {
            ToolbarItem(placement: .topBarTrailing) {
                trailingModeToggle
            }
        }
    }
}
