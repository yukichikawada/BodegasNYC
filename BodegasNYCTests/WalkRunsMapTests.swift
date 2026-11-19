//
//  WalkRunsMapTests.swift
//  BodegasNYCTests
//
//  `WalkRunsMap` (#177 PR 1, design DS6): the camera rule kept from
//  `WalkDayView` and the VoiceOver actions' names and regions.
//

import MapKit
import SwiftUI
import Testing
import UIKit

@testable import BodegasNYC

@Suite
@MainActor
struct WalkRunsMapTests {
    private typealias F = StreetFixtures

    @Observable
    final class Camera {
        var position: MapCameraPosition = .automatic
        var runs: [WalkedRun] = []
    }

    struct Host: View {
        @Bindable var camera: Camera

        var body: some View {
            WalkRunsMap(
                runs: camera.runs,
                position: $camera.position,
                accessibilityLabel: AppCopy.YourWalks.dayMapLabel.copy.text,
                accessibilityValue: "1 block, 1 new, 0.1 miles."
            )
            .frame(width: 390, height: 500)
        }
    }

    private static func same(_ lhs: MKCoordinateRegion?, _ rhs: MKCoordinateRegion) -> Bool {
        guard let lhs else { return false }
        let tolerance = 1e-9
        return abs(lhs.center.latitude - rhs.center.latitude) < tolerance
            && abs(lhs.center.longitude - rhs.center.longitude) < tolerance
            && abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < tolerance
            && abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < tolerance
    }

    /// protects=the extraction keeps `WalkDayView`'s camera rule (#177 eng
    /// AC 9): the first runs fit the camera to them (15% padding, 300 m
    /// floor), and later runs (a pass while the day is open) keep where the
    /// person panned; fails_when=the map opens unfitted, or a reload snaps
    /// the camera back; no_claim=MapKit drawing the camera or the trail
    /// (the view is hosted in an off-screen window and the camera binding
    /// is what is read), and the VoiceOver actions themselves: SwiftUI
    /// builds no accessibility nodes for an in-process query and XCUITest
    /// cannot perform a custom action on iOS 26, so their names and the
    /// regions they move to are checked in `zoomActionsScaleTheSettledRegion`.
    @Test func firstRunsFitAndAReloadKeepsThePan() async throws {
        let camera = Camera()
        camera.runs = WalkedOverlay.runs(walkedIDs: [100, 300], grid: F.cornerGrid())
        let fitted = WalkRunsMap.fittedRegion(camera.runs)
        let host = UIHostingController(rootView: Host(camera: camera))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        for _ in 0 ..< 20 where camera.position.region == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Self.same(camera.position.region, fitted), "the first runs fit the camera")

        let panned = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.70, longitude: -74.01),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )
        camera.position = .region(panned)
        camera.runs = WalkedOverlay.runs(walkedIDs: [100, 300, 400], grid: F.cornerGrid())
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.same(camera.position.region, panned), "a reload moved the camera")
    }

    /// protects=the zoom actions halve or double the settled span about the
    /// same centre, within MapKit's limits, and Show Whole Walk is the
    /// fitted region; fails_when=a zoom moves the centre, goes the wrong
    /// way, or passes 90 by 180 degrees; no_claim=the animation.
    @Test func zoomActionsScaleTheSettledRegion() {
        let settled = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.03)
        )
        let zoomIn = WalkRunsMap.CameraAction.zoomIn.region(from: settled, runs: [])
        #expect(Self.same(zoomIn, MKCoordinateRegion(center: settled.center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.015))))
        let zoomOut = WalkRunsMap.CameraAction.zoomOut.region(from: settled, runs: [])
        #expect(Self.same(zoomOut, MKCoordinateRegion(center: settled.center, span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.06))))
        let wide = MKCoordinateRegion(center: settled.center, span: MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 150))
        let capped = WalkRunsMap.CameraAction.zoomOut.region(from: wide, runs: [])
        #expect(capped.span.latitudeDelta == 90 && capped.span.longitudeDelta == 180)
        let runs = WalkedOverlay.runs(walkedIDs: [100], grid: F.cornerGrid())
        #expect(Self.same(WalkRunsMap.CameraAction.showWholeWalk.region(from: settled, runs: runs), WalkRunsMap.fittedRegion(runs)))
        #expect(WalkRunsMap.CameraAction.allCases.map(\.name) == ["Zoom In", "Zoom Out", "Show Whole Walk"])
    }
}
