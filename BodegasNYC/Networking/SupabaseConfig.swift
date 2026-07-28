import Foundation

/// A Supabase project's connection details.
nonisolated struct SupabaseConfig: Sendable {
    var projectURL: URL
    var anonKey: String
}

extension SupabaseConfig {
    /// Failure modes when loading connection details out of an Info.plist-backed
    /// bundle dictionary — `SUPABASE_URL`/`SUPABASE_ANON_KEY`, populated at build
    /// time via `INFOPLIST_KEY_SUPABASE_URL`/`INFOPLIST_KEY_SUPABASE_ANON_KEY`.
    enum LoadError: Error, Equatable {
        case missingURL
        case invalidURL(String)
        case missingAnonKey
    }

    init(infoDictionary: [String: Any]) throws {
        guard let urlString = infoDictionary["SUPABASE_URL"] as? String, !urlString.isEmpty else {
            throw LoadError.missingURL
        }
        guard let url = URL(string: urlString) else {
            throw LoadError.invalidURL(urlString)
        }
        guard let anonKey = infoDictionary["SUPABASE_ANON_KEY"] as? String, !anonKey.isEmpty else {
            throw LoadError.missingAnonKey
        }
        self.init(projectURL: url, anonKey: anonKey)
    }

    /// Loads connection details baked into the app bundle's Info.plist at build time.
    init(bundle: Bundle = .main) throws {
        try self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }
}
