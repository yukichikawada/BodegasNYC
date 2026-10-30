import SwiftUI

/// The toolbar filter button's sheet: one toggle per data point (AND
/// semantics — see `BodegaFilter`), the list's order, and a Clear Filters
/// action. Edits `filter` and `order` live rather than staging changes behind
/// an Apply button, so the map/list underneath updates as toggles flip.
///
/// Sections, top to bottom (#81 design D1): Must Have, List Order, Search.
/// List Order is an inline picker (two checkmark rows that wrap at every
/// Dynamic Type size) with exactly one footer line, chosen by
/// `ListOrder.sheetFooter` from `isNearestOrdered` (the list holds a pinned
/// fix, eng R4) and `canBePromptedForLocation` (the tips' mirror), and
/// updated live while the sheet is open. The order is not a filter: Clear
/// Filters leaves it alone, and it never counts toward the badge. The sheet
/// never offers Locate Me or a Settings link (design D2; PRD §4.2).
///
/// The search text itself is edited via the list's `.searchable` field;
/// it's only surfaced here (when non-blank) so a search typed on the List
/// tab is visible — and clearable — from the Map tab too, which has no
/// search field of its own.
struct BodegaFilterSheet: View {
    @Binding var filter: BodegaFilter
    @Binding var order: ListOrder
    var isNearestOrdered = false
    var canBePromptedForLocation = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("Must Have") {
                    ForEach(BodegaFilter.Amenity.allCases) { amenity in
                        Toggle(isOn: binding(for: amenity)) {
                            Label(amenity.label, systemImage: amenity.systemImage)
                        }
                        .accessibilityLabel(amenity.accessibilityLabel)
                    }
                }
                // iOS switches ignore the AccentColor asset (DESIGN.md Colors).
                .tint(.accentColor)
                listOrderSection
                if !filter.trimmedSearchText.isEmpty {
                    Section("Search") {
                        LabeledContent("Name or address contains", value: filter.trimmedSearchText)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppCopy.clearFiltersAction.copy.text) { filter = .none }
                        .disabled(!filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // At accessibility sizes a half sheet shows little more than the
        // title (the DuplicateBodegaSheet precedent, design D5).
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private var listOrderSection: some View {
        Section {
            Picker(AppCopy.listOrderSectionLabel.copy.text, selection: $order) {
                ForEach(ListOrder.allCases) { order in
                    Text(order.label.copy.text).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text(AppCopy.listOrderSectionLabel.copy.text)
        } footer: {
            if let footer = ListOrder.sheetFooter(
                for: order,
                isNearestOrdered: isNearestOrdered,
                canBePromptedForLocation: canBePromptedForLocation
            ) {
                Text(footer.copy.text)
            }
        }
        // The checkmarks in Deli Green; form controls ignore the asset.
        .tint(.accentColor)
    }

    private func binding(for amenity: BodegaFilter.Amenity) -> Binding<Bool> {
        Binding(
            get: { filter.requires(amenity) },
            set: { filter.setRequired(amenity, $0) }
        )
    }
}
