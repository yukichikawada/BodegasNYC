import Foundation

/// A Supabase project's connection details. Deliberately has no
/// bundle/Info.plist loading logic — nothing in this slice (no ViewModels,
/// no app-level composition root) constructs one yet, and there's no live
/// project's real URL/anon key to load until that follow-up step happens.
nonisolated struct SupabaseConfig: Sendable {
    var projectURL: URL
    var anonKey: String
}
