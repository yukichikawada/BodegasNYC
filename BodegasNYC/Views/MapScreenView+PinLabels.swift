import MapKit
import SwiftUI
import UIKit

// Pin labels at block zoom (#67): when the map recomputes which pins show
// their name. Points come from `MapProxy.convert`, so heading and pitch are
// honoured, and only ever from actions, never from `body` (converting while
// rendering made every `Map` update invalidate the view again, see
// `PinMotionState.placeAnchor`). Labels change only at a settle, on rotation
// and on the Map tab's return; data and priority changes that land while the
// camera moves wait for the settle (eng D1), and a zoom gesture clears them
// (design D9).
extension MapScreenView {
    /// The pins placed first and always labelled: held, then dropping. The
    /// tapped pin (`selectedItemID`) is cleared on every tap, so it is not a
    /// lasting priority.
    var labelPriorityIDs: [Bodega.ID] {
        var seen = Set<Bodega.ID>()
        return [pinMotion.phase.bodega?.id, viewModel.highlightedBodegaID]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    /// Selected, held and highlighted pins declared last. MapKit stacks by screen
    /// position, so this only settles ties at equal height (see
    /// `BodegaMapViewModel.drawOrdered`, #59).
    var orderedDisplayItems: [MapDisplayItem] {
        let selected = selectedItemID.flatMap(UUID.init(uuidString:))
        let front = Set(labelPriorityIDs + [selected].compactMap { $0 })
        return BodegaMapViewModel.drawOrdered(viewModel.displayItems, frontIDs: front)
    }

    /// The label triggers that are not the settle: map size (device
    /// rotation), the Dynamic Type size, priority and data changes, and the
    /// continuous camera handler.
    func pinLabelTriggers(_ content: some View, proxy: MapProxy) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                mapSize = size
                mapResizedAt = Date()
                refreshPinLabels(proxy)
            }
            .onChange(of: dynamicTypeSize) { refreshPinLabels(proxy) }
            .onChange(of: labelPriorityIDs) {
                guard !isCameraMoving else { return }
                refreshPinLabels(proxy)
            }
            // A version, not the array: cheap to compare, and a recluster the
            // settle refresh already placed is skipped.
            .onChange(of: viewModel.displayItemsVersion) { _, version in
                guard !isCameraMoving, viewModel.pinLabels.placedItemsVersion != version else { return }
                refreshPinLabels(proxy)
            }
            .onMapCameraChange(frequency: .continuous) { context in
                guard let settled = lastSettledCamera else { return }
                // A trailing callback at the settled camera must not mark it
                // moving again (nothing would clear the flag).
                guard Self.hasMoved(from: settled, to: context.camera) else { return }
                if !isCameraMoving { isCameraMoving = true }
                if abs(context.camera.distance - settled.distance) / settled.distance > 0.10 {
                    viewModel.pinLabels.clear()
                }
            }
    }

    /// Whether `camera` differs from `settled` beyond float noise: 0.5 m of
    /// distance, about 0.1 m of centre, 0.1° of heading or pitch.
    private static func hasMoved(from settled: MapCamera, to camera: MapCamera) -> Bool {
        abs(camera.distance - settled.distance) > 0.5
            || abs(camera.centerCoordinate.latitude - settled.centerCoordinate.latitude) > 1e-6
            || abs(camera.centerCoordinate.longitude - settled.centerCoordinate.longitude) > 1e-6
            || abs(camera.heading - settled.heading) > 0.1
            || abs(camera.pitch - settled.pitch) > 0.1
    }

    /// The camera settled: recluster (held back under the List tab, where
    /// nothing may refetch or recluster), then place labels on the result.
    func cameraDidSettle(_ context: MapCameraUpdateContext, proxy: MapProxy) {
        lastVisibleRegion = context.region
        isCameraMoving = false
        countLocateTakeover(settledAt: context.camera)
        lastSettledCamera = context.camera
        guard showsToolbar else {
            pendingSettledRegion = context.region
            return
        }
        deliveredRegion = context.region
        viewModel.regionDidSettle(context.region)
        refreshPinLabels(proxy)
        addCompletion?.cameraDidSettle(center: Coordinate(context.region.center))
    }

    /// The Map tab is back: deliver the settle parked under the List tab,
    /// then always recompute (items, priorities or size may have changed
    /// while refreshes were suppressed).
    func mapTabDidReturn(_ proxy: MapProxy) {
        if let region = pendingSettledRegion {
            pendingSettledRegion = nil
            if !region.isSameCamera(as: deliveredRegion) {
                deliveredRegion = region
                viewModel.regionDidSettle(region)
            }
        }
        refreshPinLabels(proxy)
    }

    /// Converts the items near the visible region (and the user-location dot,
    /// an obstacle) to screen points and hands them to placement.
    func refreshPinLabels(_ proxy: MapProxy) {
        // The bottom centre is on the ground even with the horizon in view;
        // when it does not convert, the map cannot answer yet (before its
        // first layout, and once seen live right after a settle's
        // recluster), so the current labels stay rather than being cleared.
        guard showsToolbar, mapSize.height > 0,
              let bottom = proxy.convert(CGPoint(x: mapSize.width / 2, y: mapSize.height), from: .local)
        else { return }
        viewModel.pinLabels.placedItemsVersion = viewModel.displayItemsVersion
        let contentSize = UIContentSizeCategory(dynamicTypeSize)
        let isBlockZoom = visibleHeightMeters(proxy, bottom: bottom).map {
            BodegaMapViewModel.isBlockZoom(heightMeters: $0, wasBlockZoom: viewModel.pinLabels.isBlockZoom)
        } ?? false
        // Above block zoom nothing is converted: placement returns no labels.
        guard isBlockZoom else {
            viewModel.updatePinLabels(
                items: [], points: [:], isBlockZoom: false, priorityIDs: [], contentSize: contentSize
            )
            return
        }
        let region = lastVisibleRegion ?? Self.newYorkCityDefault
        var items = viewModel.displayItems
        // The held pin outside `displayItems` is drawn by its stand-in: it is
        // both a priority candidate and an obstacle (eng F1).
        if let standIn = pinMotion.standIn(among: items) {
            items.append(.pin(standIn))
        }
        items = BodegaMapViewModel.labelCandidates(items, near: region)
        var points: [String: CGPoint] = [:]
        for item in items {
            points[item.id] = proxy.convert(item.coordinate.clLocationCoordinate, to: .local)
        }
        if let dot = userLocation?.coordinate {
            points[BodegaMapViewModel.userLocationObstacleID] = proxy.convert(dot.clLocationCoordinate, to: .local)
        }
        viewModel.updatePinLabels(
            items: items,
            points: points,
            isBlockZoom: true,
            priorityIDs: labelPriorityIDs,
            contentSize: contentSize
        )
    }

    /// The map's visible height in metres, top-centre to bottom-centre of its
    /// bounds (design D4: heading does not change it). `nil` when the top
    /// does not land on the map (the horizon is in view).
    private func visibleHeightMeters(_ proxy: MapProxy, bottom: CLLocationCoordinate2D) -> Double? {
        guard let top = proxy.convert(CGPoint(x: mapSize.width / 2, y: 0), from: .local) else { return nil }
        let meters = Coordinate(top).distance(to: Coordinate(bottom))
        // Before the map has laid out, both points convert to the same
        // coordinate: no measure yet, not block zoom.
        return meters > 0 ? meters : nil
    }
}
