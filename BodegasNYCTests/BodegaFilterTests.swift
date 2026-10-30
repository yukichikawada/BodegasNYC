//
//  BodegaFilterTests.swift
//  BodegasNYCTests
//
//  Pure matching logic, no networking involved — a standalone suite like
//  BodegaClusteringTests, not nested under NetworkingTests.
//

import Testing

@testable import BodegasNYC

@Suite
struct BodegaFilterTests {
    @Test func noneMatchesEverythingAndIsInactive() throws {
        let plain = try makeTestBodega()
        let loaded = try makeTestBodega(
            address: "1 Main St",
            hasCat: true,
            servesHotFood: true,
            sellsCigarettes: true,
            sellsBeer: true,
            sellsLotto: true
        )

        #expect(BodegaFilter.none.matches(plain))
        #expect(BodegaFilter.none.matches(loaded))
        #expect(!BodegaFilter.none.isActive)
        #expect(BodegaFilter.none.activeCount == 0)
    }

    /// protects: requiring one amenity keeps a bodega with that data point
    /// and drops one without it, for all six (ATM since #141).
    /// fails_when: an amenity's `isSatisfied(by:)` reads another field or
    /// none, or requiring it does not count once in the badge.
    /// no_claim: combinations (see `combinedAmenitiesUseANDSemantics`).
    @Test(arguments: BodegaFilter.Amenity.allCases)
    func eachAmenityRequiresItsOwnDataPoint(_ amenity: BodegaFilter.Amenity) throws {
        let without = try makeTestBodega()
        let with = try makeTestBodega(
            hasCat: amenity == .hasCat,
            servesHotFood: amenity == .servesHotFood,
            sellsCigarettes: amenity == .sellsCigarettes,
            sellsBeer: amenity == .sellsBeer,
            sellsLotto: amenity == .sellsLotto,
            hasAtm: amenity == .hasAtm
        )
        var filter = BodegaFilter.none
        filter.setRequired(amenity, true)

        #expect(filter.matches(with))
        #expect(!filter.matches(without))
        #expect(filter.isActive)
        #expect(filter.activeCount == 1)
    }

    @Test func combinedAmenitiesUseANDSemantics() throws {
        let catOnly = try makeTestBodega(hasCat: true)
        let hotFoodOnly = try makeTestBodega(servesHotFood: true)
        let both = try makeTestBodega(hasCat: true, servesHotFood: true)
        let bothPlusBeer = try makeTestBodega(hasCat: true, servesHotFood: true, sellsBeer: true)
        let filter = BodegaFilter(requiredAmenities: [.hasCat, .servesHotFood])

        #expect(!filter.matches(catOnly))
        #expect(!filter.matches(hotFoodOnly))
        #expect(filter.matches(both))
        #expect(filter.matches(bothPlusBeer))
        #expect(filter.activeCount == 2)
    }

    @Test func setRequiredFalseRemovesTheAmenity() {
        var filter = BodegaFilter(requiredAmenities: [.sellsLotto, .sellsBeer])
        filter.setRequired(.sellsLotto, false)

        #expect(filter.requiredAmenities == [.sellsBeer])
        #expect(!filter.requires(.sellsLotto))
    }

    @Test func searchMatchesName() throws {
        let bodega = try makeTestBodega(name: "El Sol Deli", address: "100 Ave A")

        #expect(BodegaFilter(searchText: "Sol").matches(bodega))
        #expect(!BodegaFilter(searchText: "Luna").matches(bodega))
    }

    @Test func searchMatchesAddress() throws {
        let bodega = try makeTestBodega(name: "El Sol Deli", address: "100 Avenue A")

        #expect(BodegaFilter(searchText: "Avenue A").matches(bodega))
    }

    @Test func searchNeverMatchesAMissingAddress() throws {
        let bodega = try makeTestBodega(name: "El Sol Deli", address: nil)

        #expect(!BodegaFilter(searchText: "Avenue").matches(bodega))
    }

    @Test func searchIsCaseAndDiacriticInsensitive() throws {
        let bodega = try makeTestBodega(name: "Café Olé Grocery")

        #expect(BodegaFilter(searchText: "cafe ole").matches(bodega))
        #expect(BodegaFilter(searchText: "GROCERY").matches(bodega))
    }

    @Test func searchTextIsTrimmed() throws {
        let bodega = try makeTestBodega(name: "El Sol Deli")
        let padded = BodegaFilter(searchText: "  sol \n")

        #expect(padded.matches(bodega))
        #expect(padded.trimmedSearchText == "sol")
        #expect(padded.activeCount == 1)
    }

    @Test func whitespaceOnlySearchIsInactiveAndMatchesEverything() throws {
        let bodega = try makeTestBodega(name: "El Sol Deli")
        let blank = BodegaFilter(searchText: "   ")

        #expect(!blank.isActive)
        #expect(blank.activeCount == 0)
        #expect(blank.matches(bodega))
    }

    @Test func clearingAmenitiesDropsTogglesAndKeepsSearchText() {
        let filter = BodegaFilter(requiredAmenities: [.hasCat, .sellsBeer], searchText: "deli ")

        let cleared = filter.clearingAmenities()

        #expect(cleared.requiredAmenities.isEmpty)
        #expect(cleared.searchText == "deli ")
        #expect(cleared.activeCount == 1)
        // The original is untouched; this returns a copy.
        #expect(filter.requiredAmenities == [.hasCat, .sellsBeer])
    }

    @Test func clearingAmenitiesOnAnAmenityOnlyFilterIsInactive() {
        let cleared = BodegaFilter(requiredAmenities: [.servesHotFood]).clearingAmenities()

        #expect(cleared == .none)
        #expect(!cleared.isActive)
    }

    // #57: the map card's Clear Filters is decided by outcome, so one tap
    // always brings pins back.
    private func mapCardFixtures() throws -> [Bodega] {
        [
            try makeTestBodega(name: "Plain Deli"),
            try makeTestBodega(name: "Corner Grocery")
        ]
    }

    @Test func clearingForMapCardKeepsTheSearchWhenClearingTogglesRevealsPins() throws {
        // DD6: the search alone still matches "Plain Deli".
        let filter = BodegaFilter(requiredAmenities: [.hasCat], searchText: "deli")

        let cleared = filter.clearingForMapCard(in: try mapCardFixtures())

        #expect(cleared == BodegaFilter(searchText: "deli"))
    }

    @Test func clearingForMapCardClearsEverythingWhenClearingTogglesRevealsNothing() throws {
        let filter = BodegaFilter(requiredAmenities: [.hasCat], searchText: "zzz")

        #expect(filter.clearingForMapCard(in: try mapCardFixtures()) == .none)
    }

    @Test func clearingForMapCardWithOnlyASearchClearsTheSearch() throws {
        let filter = BodegaFilter(searchText: "zzz")

        #expect(filter.clearingForMapCard(in: try mapCardFixtures()) == .none)
    }

    @Test func searchAndAmenitiesMustBothMatch() throws {
        let catDeli = try makeTestBodega(name: "Cat Deli", hasCat: true)
        let catlessDeli = try makeTestBodega(name: "Plain Deli")
        let catGrocery = try makeTestBodega(name: "Cat Grocery", hasCat: true)
        let filter = BodegaFilter(requiredAmenities: [.hasCat], searchText: "deli")

        #expect(filter.matches(catDeli))
        #expect(!filter.matches(catlessDeli))
        #expect(!filter.matches(catGrocery))
        #expect(filter.activeCount == 2)
    }

    /// The Filters sheet's section is titled "Must Have", so the visible
    /// label is the bare noun; the verb lives in the VoiceOver label, which
    /// is read without the section title.
    ///
    /// protects: the bare-noun / verb split, ATM's label, VoiceOver label,
    /// symbol and last place (#141), and one label source per amenity:
    /// `label` is its `caption` text (#141 design DS6).
    /// fails_when: a label gains a verb, a VoiceOver label loses it, ATM's
    /// strings or symbol drift, ATM moves off the end, or `label` and
    /// `caption` diverge.
    /// no_claim: how the strings render on any surface.
    @Test func amenityLabelsAreBareNounsAndAccessibilityLabelsCarryTheVerb() {
        let verbs = ["Has ", "Sells ", "Serves "]
        for amenity in BodegaFilter.Amenity.allCases {
            #expect(!verbs.contains { amenity.label.hasPrefix($0) }, "\(amenity)")
            #expect(verbs.contains { amenity.accessibilityLabel.hasPrefix($0) }, "\(amenity)")
            #expect(amenity.accessibilityLabel.hasSuffix(amenity.label), "\(amenity)")
            #expect(amenity.label == amenity.caption.copy.text, "\(amenity)")
        }
        #expect(BodegaFilter.Amenity.sellsCigarettes.label == "Nicotine")
        #expect(BodegaFilter.Amenity.sellsCigarettes.systemImage == "cross")
        #expect(BodegaFilter.Amenity.hasAtm.label == "ATM")
        #expect(BodegaFilter.Amenity.hasAtm.accessibilityLabel == "Has an ATM")
        #expect(BodegaFilter.Amenity.hasAtm.systemImage == "banknote")
        #expect(BodegaFilter.Amenity.allCases.last == .hasAtm)
    }
}
