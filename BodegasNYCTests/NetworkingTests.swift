//
//  NetworkingTests.swift
//  BodegasNYCTests
//
//  Umbrella namespace for every Supabase networking-layer test suite
//  (SupabaseFetchTests, BodegaServiceTests, ReviewServiceTests,
//  PhotoServiceTests, FlagServiceTests — each nested in via `extension
//  NetworkingTests` in its own file). `.serialized` on a suite applies
//  recursively to nested suites, so every test here runs one at a time.
//
//  This is required, not just tidiness: `MockURLProtocol`'s stub queue is
//  shared process-wide static state, and Swift Testing runs separate
//  top-level suites concurrently by default — confirmed by a real run where
//  two suites' network calls raced and stole each other's stubbed
//  responses (decode type-mismatches on the wrong JSON shape, "keyNotFound"
//  on a completely different row shape, empty-queue NSURLErrorDomain -1).
//  Nesting everything under one `.serialized` parent is what actually fixes
//  that, not just the per-file `@Suite(.serialized)` these already had
//  (which only serializes *within* one file's suite).
//

import Testing

@Suite(.serialized)
struct NetworkingTests {}
