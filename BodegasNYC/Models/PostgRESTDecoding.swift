import Foundation

/// Builds a `JSONDecoder` configured for PostgREST's timestamp format.
///
/// PostgREST serializes `timestamptz` columns as ISO-8601 strings, but
/// `JSONDecoder`'s built-in `.iso8601` strategy uses an `ISO8601DateFormatter`
/// with no fractional-seconds support — and real rows almost always have
/// fractional seconds (`now()` has microsecond precision), so the naive
/// `.iso8601` strategy fails to decode most real PostgREST timestamps. This
/// tries a fractional-seconds formatter first, then falls back to the
/// no-fraction case, so both shapes decode correctly.
nonisolated enum PostgRESTDecoding {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = fractionalSecondsFormatter.date(from: string) {
                return date
            }
            if let date = wholeSecondsFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date string, got \"\(string)\""
            )
        }
        return decoder
    }

    // `ISO8601DateFormatter` isn't `Sendable` (Foundation hasn't audited it),
    // but these are configured once and never mutated afterward, and
    // `date(from:)` is safe to call concurrently on a shared instance in
    // practice — `nonisolated(unsafe)` scopes that trust to just these two
    // properties, rather than reaching for `@unchecked Sendable` on a type.
    private nonisolated(unsafe) static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let wholeSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
