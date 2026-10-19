import SwiftUI

/// The toolbar filter button's sheet: one toggle per data point (AND
/// semantics — see `BodegaFilter`) and a Clear action. Edits `filter` live
/// rather than staging changes behind an Apply button, so the map/list
/// underneath updates as toggles flip.
///
/// The search text itself is edited via the list's `.searchable` field;
/// it's only surfaced here (when non-blank) so a search typed on the List
/// tab is visible — and clearable — from the Map tab too, which has no
/// search field of its own.
struct BodegaFilterSheet: View {
    @Binding var filter: BodegaFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Must Have") {
                    ForEach(BodegaFilter.Amenity.allCases) { amenity in
                        Toggle(isOn: binding(for: amenity)) {
                            Label(amenity.label, systemImage: amenity.systemImage)
                        }
                    }
                }
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
                    Button("Clear") { filter = .none }
                        .disabled(!filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(for amenity: BodegaFilter.Amenity) -> Binding<Bool> {
        Binding(
            get: { filter.requires(amenity) },
            set: { filter.setRequired(amenity, $0) }
        )
    }
}
