//
//  BodegasNYCApp.swift
//  BodegasNYC
//
//  Created by Yukichi Kawada on 7/21/26.
//

import SwiftUI
import TipKit

@main
struct BodegasNYCApp: App {
    init() {
        #if DEBUG
        // QA: launch with `-ResetTips` to wipe TipKit's datastore before it
        // loads, so the first-run tutorial tips (#22) show again. It must run
        // before `configure`. Pair it with a fresh install (or cleared
        // defaults) to replay onboarding too.
        if CommandLine.arguments.contains("-ResetTips") {
            try? Tips.resetDatastore()
        }
        UITestFixtures.registerForSharedSession()
        #endif
        // Photos are immutable (uuid paths), and the gallery and the viewer
        // load the same images, so a larger shared cache saves refetching
        // them on every viewer open (#107 eng C3).
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 300_000_000)
        // `.immediate`: the tutorial's tips are gated by their own rules,
        // not by TipKit's default once-a-day pacing.
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
