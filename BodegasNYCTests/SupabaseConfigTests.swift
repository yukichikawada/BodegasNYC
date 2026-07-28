//
//  SupabaseConfigTests.swift
//  BodegasNYCTests
//
//  Verifies SupabaseConfig's Info.plist-dictionary loading, independent of
//  Bundle.main, since the real bundle's values depend on build settings
//  (SUPABASE_URL/SUPABASE_ANON_KEY) that aren't present in the test target.
//

import Testing
import Foundation
@testable import BodegasNYC

struct SupabaseConfigTests {

    @Test func loadsFromInfoDictionary() throws {
        let config = try SupabaseConfig(infoDictionary: [
            "SUPABASE_URL": "https://fdzjfdvotkodwimtsiuu.supabase.co",
            "SUPABASE_ANON_KEY": "test-anon-key"
        ])

        #expect(config.projectURL == URL(string: "https://fdzjfdvotkodwimtsiuu.supabase.co"))
        #expect(config.anonKey == "test-anon-key")
    }

    @Test func throwsWhenURLMissing() {
        #expect(throws: SupabaseConfig.LoadError.missingURL) {
            try SupabaseConfig(infoDictionary: ["SUPABASE_ANON_KEY": "test-anon-key"])
        }
    }

    @Test func throwsWhenURLEmpty() {
        #expect(throws: SupabaseConfig.LoadError.missingURL) {
            try SupabaseConfig(infoDictionary: ["SUPABASE_URL": "", "SUPABASE_ANON_KEY": "test-anon-key"])
        }
    }

    @Test func throwsWhenURLMalformed() {
        let malformed = "http://[::1"
        #expect(throws: SupabaseConfig.LoadError.invalidURL(malformed)) {
            try SupabaseConfig(infoDictionary: ["SUPABASE_URL": malformed, "SUPABASE_ANON_KEY": "test-anon-key"])
        }
    }

    @Test func throwsWhenAnonKeyMissing() {
        #expect(throws: SupabaseConfig.LoadError.missingAnonKey) {
            try SupabaseConfig(infoDictionary: ["SUPABASE_URL": "https://fdzjfdvotkodwimtsiuu.supabase.co"])
        }
    }
}
