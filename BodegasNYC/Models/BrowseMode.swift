import Foundation

/// Which slice of bodegas a browsing screen (map or, eventually, list) shows:
/// everything (`.all`, no location permission needed) or a radius around the
/// user's current position (`.nearby`, gated behind When-In-Use
/// authorization). Lives alongside `Bodega` rather than under `ViewModels/`
/// since both the map and a future list screen need the same concept.
nonisolated enum BrowseMode: Equatable, Sendable {
    case all
    case nearby
}
