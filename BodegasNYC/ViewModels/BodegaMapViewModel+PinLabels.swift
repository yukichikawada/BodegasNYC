import CoreGraphics
import CoreLocation
import MapKit
import Observation
import UIKit

/// Which pins carry their name label at block zoom (#67). The one
/// authoritative label state: `BodegaMapViewModel.updatePinLabels` writes
/// `ids`, and `HeldPinView` reads it inside the view MapKit hosts (a `Map`
/// annotation closure does not re-render when only captured state changes).
@MainActor
@Observable
final class PinLabelState {
    private(set) var ids: Set<Bodega.ID> = []
    /// The last block-zoom verdict, the hysteresis input (design D2).
    @ObservationIgnored private(set) var isBlockZoom = false
    /// Measured capsule sizes per name, valid for `cachedCategory` only.
    @ObservationIgnored private var sizeCache: [String: CGSize] = [:]
    @ObservationIgnored private var cachedCategory: UIContentSizeCategory?

    /// Writes only when the set differs, so redundant refreshes never
    /// re-render the pins.
    func update(ids newIDs: Set<Bodega.ID>, isBlockZoom: Bool) {
        self.isBlockZoom = isBlockZoom
        if ids != newIDs { ids = newIDs }
    }

    /// Empties the labelled set during a zoom gesture (design D9). Leaves the
    /// hysteresis state alone: clearing is not recomputing.
    func clear() {
        if !ids.isEmpty { ids = [] }
    }

    /// The capsule size `BodegaPinView` draws for `name` at `contentSize`,
    /// measured once per name per content size (eng D2).
    func labelSize(for name: String, contentSize: UIContentSizeCategory) -> CGSize {
        if cachedCategory != contentSize {
            sizeCache = [:]
            cachedCategory = contentSize
        }
        if let size = sizeCache[name] { return size }
        let size = BodegaPinView.measuredLabelSize(for: name, contentSize: contentSize)
        sizeCache[name] = size
        return size
    }
}

nonisolated extension MapDisplayItem {
    var coordinate: Coordinate {
        switch self {
        case .pin(let bodega): bodega.coordinate
        case .cluster(let cluster): cluster.coordinate
        }
    }
}

/// Pin label placement (#67): pure, synchronous and unit-tested
/// (`PinLabelPlacementTests`), like `BodegaClustering.swift`.
///
/// The rule (DESIGN.md Pin, DD3): at block zoom every pin shows its label
/// unless the label would cover a kept label or another item's drawn
/// circle. Held and dropping pins are placed first and always keep theirs;
/// the rest go north to south, then by id. North-first is for pan
/// stability, not relevance: a pure pan moves every point by the same
/// vector, so the order and every pairwise overlap are unchanged and no
/// label swaps. Do not "fix" it to distance from the centre.
nonisolated extension BodegaMapViewModel {
    /// Block zoom is entered at a visible map height of 400 m or less and
    /// left above 440 m (design D2: hysteresis, so a settle near the line
    /// never blinks every label).
    static let blockZoomEnterMeters: Double = 400
    static let blockZoomExitMeters: Double = 440

    /// The label sits this far above the circle's top edge (DD3's 4pt).
    static let labelGap: CGFloat = 4
    /// Minimum gap between two kept labels: candidates are inset by this,
    /// kept rects are stored un-inset, so the gap is exactly this.
    static let labelClearance: CGFloat = 4
    /// Obstacles are the drawn circles (design D8): a 28pt pin or badge plus
    /// its 2pt stroke; the held or dropping pin at its 1.15 selected scale
    /// with a 3pt stroke; the user-location dot as drawn (the blue dot and
    /// its white ring, about 22pt; the translucent accuracy halo may be
    /// covered). Not the halo: a user standing on a pin lost that pin's and
    /// its neighbour's labels to a 44pt square (#67 QA, refining design D1).
    /// At 24pt, a label above a pin at the user's point clears the dot.
    static let itemObstacleSide: CGFloat = 32
    static let priorityObstacleSide: CGFloat = 36
    static let locationDotObstacleSide: CGFloat = 24
    /// The `points` key for the user-location dot: an obstacle, never a
    /// candidate (no item has this id).
    static let userLocationObstacleID = "user-location"

    /// Apple's commercial points of interest, hidden at every zoom so the
    /// map's only business names are ours (#67 design D1). Wayfinding stays:
    /// transit, parks, schools, universities, hospitals, libraries, museums,
    /// landmarks, airports, stadiums, national parks, beaches, zoos,
    /// aquariums, amusement parks, fire stations, police, post offices,
    /// restrooms. DESIGN.md Components, Map tiles, records the list.
    static let excludedPOICategories: [MKPointOfInterestCategory] = [
        .store, .foodMarket, .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife,
        .pharmacy, .laundry, .atm, .bank, .gasStation, .evCharger, .carRental, .hotel,
        .fitnessCenter, .movieTheater, .theater, .marina, .spa, .beauty, .automotiveRepair,
        .musicVenue
    ]

    /// Whether the camera is at block zoom, given the visible map height and
    /// the previous verdict.
    static func isBlockZoom(heightMeters: Double, wasBlockZoom: Bool) -> Bool {
        heightMeters <= (wasBlockZoom ? blockZoomExitMeters : blockZoomEnterMeters)
    }

    /// Whether `coordinate` lies inside `region` grown by `padding` times
    /// each span on every side (edges included). Only such items take part
    /// in placement (eng D3): the rest never label and never block.
    static func isNear(region: MKCoordinateRegion, coordinate: Coordinate, padding: Double = 0.5) -> Bool {
        let halfLatitude = region.span.latitudeDelta * (0.5 + padding)
        let halfLongitude = region.span.longitudeDelta * (0.5 + padding)
        return abs(coordinate.latitude - region.center.latitude) <= halfLatitude
            && abs(coordinate.longitude - region.center.longitude) <= halfLongitude
    }

    /// `items` that take part in placement around `region`.
    static func labelCandidates(_ items: [MapDisplayItem], near region: MKCoordinateRegion) -> [MapDisplayItem] {
        items.filter { isNear(region: region, coordinate: $0.coordinate) }
    }

    /// The label capsule's rect for a pin at `point`: centred on it, its
    /// bottom `labelGap` above the circle's top edge.
    static func labelRect(for name: String, at point: CGPoint, size: (String) -> CGSize) -> CGRect {
        let labelSize = size(name)
        let maxY = point.y - BodegaPinView.diameter / 2 - labelGap
        return CGRect(
            x: point.x - labelSize.width / 2,
            y: maxY - labelSize.height,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    /// The pins whose label shows. `points` is keyed by `MapDisplayItem.id`
    /// (plus `userLocationObstacleID`); an item without a point is neither a
    /// candidate nor an obstacle. `labelSize` returns the capsule size for a
    /// name. With `onlyPriority` (the first add's drop, design D11) only the
    /// priority pins are returned.
    static func labelledPinIDs(
        items: [MapDisplayItem],
        points: [String: CGPoint],
        isBlockZoom: Bool,
        priorityIDs: [Bodega.ID],
        onlyPriority: Bool = false,
        labelSize: (String) -> CGSize
    ) -> Set<Bodega.ID> {
        guard isBlockZoom else { return [] }

        var pins: [Bodega.ID: Bodega] = [:]
        for case .pin(let bodega) in items where points[bodega.id.uuidString] != nil {
            pins[bodega.id] = bodega
        }
        var seen = Set<Bodega.ID>()
        let priority = priorityIDs.filter { pins[$0] != nil && seen.insert($0).inserted }
        if onlyPriority { return Set(priority) }

        let prioritySet = Set(priority)
        let obstacles = obstacleRects(items: items, points: points, priority: prioritySet)
        let rest = pins.values.filter { !prioritySet.contains($0.id) }.sorted(by: isPlacedBefore)

        var kept = Set<Bodega.ID>()
        var keptRects: [CGRect] = []
        for id in priority {
            guard let bodega = pins[id], let point = points[id.uuidString] else { continue }
            kept.insert(id)
            keptRects.append(labelRect(for: bodega.name, at: point, size: labelSize))
        }
        for bodega in rest {
            guard let point = points[bodega.id.uuidString] else { continue }
            let rect = labelRect(for: bodega.name, at: point, size: labelSize)
            // Clearance applies between labels only. Against a circle the
            // un-inset rect is checked (design D8: two pins across a street
            // must not both lose their labels to a 4pt margin).
            let padded = rect.insetBy(dx: -labelClearance, dy: -labelClearance)
            let hitsLabel = keptRects.contains { $0.intersects(padded) }
            let hitsCircle = obstacles.contains { $0.id != bodega.id.uuidString && $0.rect.intersects(rect) }
            guard !hitsLabel, !hitsCircle else { continue }
            kept.insert(bodega.id)
            keptRects.append(rect)
        }
        return kept
    }

    /// North to south, then by id.
    private static func isPlacedBefore(_ lhs: Bodega, _ rhs: Bodega) -> Bool {
        if lhs.coordinate.latitude != rhs.coordinate.latitude {
            return lhs.coordinate.latitude > rhs.coordinate.latitude
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Every drawn circle with a point, keyed by item id, plus the location
    /// dot under `userLocationObstacleID`.
    private static func obstacleRects(
        items: [MapDisplayItem],
        points: [String: CGPoint],
        priority: Set<Bodega.ID>
    ) -> [(id: String, rect: CGRect)] {
        var obstacles: [(id: String, rect: CGRect)] = items.compactMap { item in
            guard let point = points[item.id] else { return nil }
            let isPriority = if case .pin(let bodega) = item { priority.contains(bodega.id) } else { false }
            return (item.id, square(at: point, side: isPriority ? priorityObstacleSide : itemObstacleSide))
        }
        if let dot = points[userLocationObstacleID] {
            obstacles.append((userLocationObstacleID, square(at: dot, side: locationDotObstacleSide)))
        }
        return obstacles
    }

    private static func square(at point: CGPoint, side: CGFloat) -> CGRect {
        CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
    }
}

extension BodegaMapViewModel {
    /// Recomputes `pinLabels` from the screen points `MapScreenView`
    /// converted (only it may call `MapProxy.convert`). Idempotent: an
    /// unchanged set is not written. While a just-added bodega drops
    /// (`highlightedBodegaID`), only the priority pins are labelled (design
    /// D11: the one authored moment keeps its one label).
    func updatePinLabels(
        items: [MapDisplayItem],
        points: [String: CGPoint],
        isBlockZoom: Bool,
        priorityIDs: [Bodega.ID],
        contentSize: UIContentSizeCategory
    ) {
        let ids = Self.labelledPinIDs(
            items: items,
            points: points,
            isBlockZoom: isBlockZoom,
            priorityIDs: priorityIDs,
            onlyPriority: highlightedBodegaID != nil,
            labelSize: { pinLabels.labelSize(for: $0, contentSize: contentSize) }
        )
        pinLabels.update(ids: ids, isBlockZoom: isBlockZoom)
    }
}
