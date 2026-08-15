import Foundation

/// Mirrors a row in `public.bodegas`. `location` (the PostGIS
/// `geography(Point, 4326)` column used for proximity queries) is
/// intentionally not represented here — see the generated `latitude` /
/// `longitude` columns this type decodes instead.
///
/// No `rating`/`averageRating` field: community rating is derived at query
/// time from `reviews` (`AVG(rating)`), not a stored column, so there's
/// nothing to decode yet.
nonisolated struct Bodega: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var createdBy: UUID
    var name: String
    var coordinate: Coordinate
    var address: String?
    var hasCat: Bool
    var servesHotFood: Bool
    var sellsCigarettes: Bool
    var sellsBeer: Bool
    var sellsLotto: Bool
    var hours: BodegaHours?
    var isHidden: Bool
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, address, hours
        case createdBy = "created_by"
        case latitude, longitude
        case hasCat = "has_cat"
        case servesHotFood = "serves_hot_food"
        case sellsCigarettes = "sells_cigarettes"
        case sellsBeer = "sells_beer"
        case sellsLotto = "sells_lotto"
        case isHidden = "is_hidden"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdBy = try container.decode(UUID.self, forKey: .createdBy)
        name = try container.decode(String.self, forKey: .name)
        coordinate = Coordinate(
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude)
        )
        address = try container.decodeIfPresent(String.self, forKey: .address)
        hasCat = try container.decode(Bool.self, forKey: .hasCat)
        servesHotFood = try container.decode(Bool.self, forKey: .servesHotFood)
        sellsCigarettes = try container.decode(Bool.self, forKey: .sellsCigarettes)
        sellsBeer = try container.decode(Bool.self, forKey: .sellsBeer)
        sellsLotto = try container.decode(Bool.self, forKey: .sellsLotto)
        hours = try container.decodeIfPresent(BodegaHours.self, forKey: .hours)
        isHidden = try container.decode(Bool.self, forKey: .isHidden)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(name, forKey: .name)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(hasCat, forKey: .hasCat)
        try container.encode(servesHotFood, forKey: .servesHotFood)
        try container.encode(sellsCigarettes, forKey: .sellsCigarettes)
        try container.encode(sellsBeer, forKey: .sellsBeer)
        try container.encode(sellsLotto, forKey: .sellsLotto)
        try container.encodeIfPresent(hours, forKey: .hours)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Weekly recurring hours, mirroring the `bodegas.hours` jsonb column.
/// Deliberately not `Date` for open/close: these are recurring times-of-day
/// with no associated calendar date, so representing them as `Date` would
/// force picking an arbitrary reference date and invite timezone bugs.
nonisolated struct BodegaHours: Codable, Sendable, Hashable {
    nonisolated struct DayHours: Codable, Sendable, Hashable {
        var open: String
        var close: String
        var isClosed: Bool = false
    }

    var mon: DayHours?
    var tue: DayHours?
    var wed: DayHours?
    var thu: DayHours?
    var fri: DayHours?
    var sat: DayHours?
    var sun: DayHours?
}
