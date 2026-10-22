import Foundation
import PostgREST

/// Payload for creating a bodega. Deliberately not `Bodega` itself: `id`,
/// `is_hidden`, `created_at`, `updated_at` are server-generated, and
/// `latitude`/`longitude` are `generated always as (...) stored` columns —
/// PostgREST rejects an insert/update that targets a generated column
/// directly, so this encodes the writable `location` geography column
/// instead, as PostGIS EWKT text (`SRID=4326;POINT(long lat)` — longitude
/// first, matching WKT's x/y-not-lat/long axis order).
nonisolated struct NewBodega: Encodable, Sendable {
    var createdBy: UUID
    var name: String
    var coordinate: Coordinate
    var address: String?
    var hasCat: Bool = false
    var servesHotFood: Bool = false
    var sellsCigarettes: Bool = false
    var sellsBeer: Bool = false
    var sellsLotto: Bool = false
    var hours: BodegaHours?

    private enum CodingKeys: String, CodingKey {
        case name, address, hours, location
        case createdBy = "created_by"
        case hasCat = "has_cat"
        case servesHotFood = "serves_hot_food"
        case sellsCigarettes = "sells_cigarettes"
        case sellsBeer = "sells_beer"
        case sellsLotto = "sells_lotto"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(name, forKey: .name)
        try container.encode(
            "SRID=4326;POINT(\(coordinate.longitude) \(coordinate.latitude))",
            forKey: .location
        )
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(hasCat, forKey: .hasCat)
        try container.encode(servesHotFood, forKey: .servesHotFood)
        try container.encode(sellsCigarettes, forKey: .sellsCigarettes)
        try container.encode(sellsBeer, forKey: .sellsBeer)
        try container.encode(sellsLotto, forKey: .sellsLotto)
        try container.encodeIfPresent(hours, forKey: .hours)
    }
}

/// Partial update for a bodega's editable fields (PRD: "any user can propose
/// an edit to hours/data points"). All-optional so only the keys a caller
/// sets get sent — `encode(to:)` uses `encodeIfPresent` for each `Optional`
/// property, so unset fields are omitted from the PATCH body entirely
/// rather than nulling them out. No `coordinate`/`location` field:
/// relocating a bodega isn't a PRD requirement for this slice.
///
/// Because `nil` means "leave unchanged", clearing one of the two nullable
/// columns (`address`, `hours`) has to be asked for explicitly via
/// `fieldsToClear`, which encodes a JSON `null` for that key. Without it,
/// blanking an address in the Edit Bodega form would silently keep the old
/// value server-side. A non-nil value for the same field wins.
nonisolated struct BodegaUpdate: Encodable, Sendable {
    enum ClearableField: Sendable, Hashable {
        case address
        case hours
    }

    var name: String?
    var address: String?
    var hasCat: Bool?
    var servesHotFood: Bool?
    var sellsCigarettes: Bool?
    var sellsBeer: Bool?
    var sellsLotto: Bool?
    var hours: BodegaHours?
    var fieldsToClear: Set<ClearableField> = []

    private enum CodingKeys: String, CodingKey {
        case name, address, hours
        case hasCat = "has_cat"
        case servesHotFood = "serves_hot_food"
        case sellsCigarettes = "sells_cigarettes"
        case sellsBeer = "sells_beer"
        case sellsLotto = "sells_lotto"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        if let address {
            try container.encode(address, forKey: .address)
        } else if fieldsToClear.contains(.address) {
            try container.encodeNil(forKey: .address)
        }
        try container.encodeIfPresent(hasCat, forKey: .hasCat)
        try container.encodeIfPresent(servesHotFood, forKey: .servesHotFood)
        try container.encodeIfPresent(sellsCigarettes, forKey: .sellsCigarettes)
        try container.encodeIfPresent(sellsBeer, forKey: .sellsBeer)
        try container.encodeIfPresent(sellsLotto, forKey: .sellsLotto)
        if let hours {
            try container.encode(hours, forKey: .hours)
        } else if fieldsToClear.contains(.hours) {
            try container.encodeNil(forKey: .hours)
        }
    }
}

private nonisolated struct NearbyBodegasParams: Encodable, Sendable {
    var lat: Double
    var long: Double
    var radiusMeters: Double

    private enum CodingKeys: String, CodingKey {
        case lat, long
        case radiusMeters = "radius_meters"
    }
}

/// CRUD over `public.bodegas`, matching exactly what `bodegas_select` /
/// `bodegas_insert` / `bodegas_update` RLS allow — no delete method, since
/// no delete policy exists on the table (default deny).
nonisolated struct BodegaService: Sendable {
    private let postgrest: PostgrestClient

    init(postgrest: PostgrestClient) {
        self.postgrest = postgrest
    }

    /// PostgREST caps every response at `max_rows` (1000, `supabase/config.toml`),
    /// so `fetchAll()` pages with `.range` until a short page.
    private static let fetchAllPageSize = 1000

    func fetchAll() async throws -> [Bodega] {
        let pageSize = Self.fetchAllPageSize
        var bodegas: [Bodega] = []
        while true {
            // `id` breaks `created_at` ties so offset pages can't overlap or skip a row.
            let page: [Bodega] = try await postgrest
                .from("bodegas")
                .select()
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .range(from: bodegas.count, to: bodegas.count + pageSize - 1)
                .execute()
                .value
            bodegas += page
            if page.count < pageSize { return bodegas }
        }
    }

    /// Proximity search via the `nearby_bodegas` RPC (see
    /// `supabase/migrations/20260728120000_create_nearby_bodegas_function.sql`)
    /// — PostgREST can't express `ST_DWithin` filtering through plain
    /// query-string filters on a geography column.
    func fetchNearby(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 1000
    ) async throws -> [Bodega] {
        try await postgrest
            .rpc(
                "nearby_bodegas",
                params: NearbyBodegasParams(lat: latitude, long: longitude, radiusMeters: radiusMeters)
            )
            .execute()
            .value
    }

    @discardableResult
    func insert(_ draft: NewBodega) async throws -> Bodega {
        try await postgrest
            .from("bodegas")
            .insert(draft)
            .select()
            .single()
            .execute()
            .value
    }

    @discardableResult
    func update(id: UUID, _ values: BodegaUpdate) async throws -> Bodega {
        try await postgrest
            .from("bodegas")
            .update(values)
            .eq("id", value: id)
            .select()
            .single()
            .execute()
            .value
    }
}
