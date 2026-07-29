import SwiftUI

/// The list screen: a flat, `.all`-only list of bodegas (see
/// `BodegaListViewModel`'s doc comment for why there's no nearby-mode
/// toggle yet). Lives inside `BrowseView`'s single `NavigationStack` — rows
/// push to detail via `NavigationLink(value:)` against that ancestor
/// stack's `.navigationDestination(for: Bodega.self)`, so this view needs
/// no navigation callback of its own, unlike `MapScreenView`.
///
/// Takes an already-built `BodegaListViewModel` rather than constructing
/// one internally — `BrowseView` owns it so it survives Map↔List tab
/// switches instead of being torn down and rebuilt (and refetched) every
/// time this view remounts.
struct BodegaListView: View {
    let viewModel: BodegaListViewModel

    var body: some View {
        content
            .task { viewModel.loadInitialIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView()
        case .loaded where viewModel.bodegas.isEmpty:
            ContentUnavailableView(
                "No bodegas yet",
                systemImage: "cart",
                description: Text("Be the first to add one.")
            )
        case .loaded:
            List(viewModel.bodegas) { bodega in
                NavigationLink(value: bodega) {
                    BodegaRow(bodega: bodega)
                }
            }
            .listStyle(.plain)
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't load bodegas",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}

private struct BodegaRow: View {
    let bodega: Bodega

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bodega.name)
                .font(.headline)
            if let address = bodega.address {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
