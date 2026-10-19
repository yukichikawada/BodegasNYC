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

    @Test(arguments: BodegaFilter.Amenity.allCases)
    func eachAmenityRequiresItsOwnDataPoint(_ amenity: BodegaFilter.Amenity) throws {
        let without = try makeTestBodega()
        let with = try makeTestBodega(
            hasCat: amenity == .hasCat,
            servesHotFood: amenity == .servesHotFood,
            sellsCigarettes: amenity == .sellsCigarettes,
            sellsBeer: amenity == .sellsBeer,
            sellsLotto: amenity == .sellsLotto
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
}
