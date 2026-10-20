import Foundation

/// What the browse surfaces (map and list) narrow their already-fetched
/// bodegas down to: any combination of the five data points, plus a
/// free-text name/address search. Applied entirely client-side against the
/// in-memory set each view model already holds — deliberately not pushed
/// into `BodegaService`'s queries, so `.nearby`'s radius refetches and the
/// `currentFetchGeneration` guards stay exactly as they are.
///
/// Lives alongside `BrowseMode` for the same reason it does: one concept
/// shared by both browse screens, owned by `BrowseView` so switching tabs
/// never loses it.
nonisolated struct BodegaFilter: Equatable, Sendable {
    /// One of `Bodega`'s five yes/no data points.
    nonisolated enum Amenity: String, CaseIterable, Identifiable, Sendable {
        case hasCat
        case servesHotFood
        case sellsCigarettes
        case sellsBeer
        case sellsLotto

        var id: Self { self }

        var label: String {
            switch self {
            case .hasCat: "Has a Cat"
            case .servesHotFood: "Serves Hot Food"
            case .sellsCigarettes: "Sells Cigarettes"
            case .sellsBeer: "Sells Beer"
            case .sellsLotto: "Sells Lotto"
            }
        }

        var systemImage: String {
            switch self {
            case .hasCat: "cat"
            case .servesHotFood: "flame"
            case .sellsCigarettes: "smoke"
            case .sellsBeer: "mug"
            case .sellsLotto: "ticket"
            }
        }

        func isSatisfied(by bodega: Bodega) -> Bool {
            switch self {
            case .hasCat: bodega.hasCat
            case .servesHotFood: bodega.servesHotFood
            case .sellsCigarettes: bodega.sellsCigarettes
            case .sellsBeer: bodega.sellsBeer
            case .sellsLotto: bodega.sellsLotto
            }
        }
    }

    /// AND semantics: a bodega must satisfy *every* amenity in here.
    var requiredAmenities: Set<Amenity> = []
    /// Raw text as typed — bound directly to `.searchable`, so it must not
    /// be trimmed on write (the user couldn't type a space between words).
    /// Matching and `activeCount` use `trimmedSearchText` instead.
    var searchText: String = ""

    static let none = BodegaFilter()

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool { activeCount > 0 }

    /// Each required amenity counts as one, plus one for a non-blank search
    /// — what the toolbar filter button badges. Search counts because the
    /// map tab has no search field of its own, so the badge is the only
    /// signal there that a search from the list is still narrowing pins.
    var activeCount: Int {
        requiredAmenities.count + (trimmedSearchText.isEmpty ? 0 : 1)
    }

    /// What the list's no-matches Clear Filters action applies (design
    /// DD6): drops every amenity toggle but keeps the search text, so
    /// clearing filters never also throws away what the user typed (the
    /// list's search field is right there). The map card uses
    /// `clearingForMapCard(in:)` instead.
    func clearingAmenities() -> BodegaFilter {
        var copy = self
        copy.requiredAmenities = []
        return copy
    }

    /// What the map's no-matches card's Clear Filters applies (#57),
    /// decided by outcome against the loaded `bodegas`: DD6's
    /// `clearingAmenities()` when that brings back at least one pin, and
    /// otherwise `.none`. The map has no search field, so a search that
    /// on its own matches nothing would leave the card stuck after an
    /// amenities-only clear; one tap must always bring pins back.
    func clearingForMapCard(in bodegas: [Bodega]) -> BodegaFilter {
        let amenitiesCleared = clearingAmenities()
        return bodegas.contains(where: amenitiesCleared.matches) ? amenitiesCleared : .none
    }

    func requires(_ amenity: Amenity) -> Bool {
        requiredAmenities.contains(amenity)
    }

    mutating func setRequired(_ amenity: Amenity, _ isRequired: Bool) {
        if isRequired {
            requiredAmenities.insert(amenity)
        } else {
            requiredAmenities.remove(amenity)
        }
    }

    /// True when `bodega` has every required amenity and — if there's a
    /// non-blank search — its name or address contains that text.
    /// `localizedStandardContains` is case- and diacritic-insensitive, so
    /// "cafe" finds "Café" and "deli" finds "DELI".
    func matches(_ bodega: Bodega) -> Bool {
        guard requiredAmenities.allSatisfy({ $0.isSatisfied(by: bodega) }) else { return false }
        let query = trimmedSearchText
        guard !query.isEmpty else { return true }
        if bodega.name.localizedStandardContains(query) { return true }
        return bodega.address?.localizedStandardContains(query) ?? false
    }
}
