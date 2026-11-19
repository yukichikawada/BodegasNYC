import MapKit
import SwiftUI

/// A walk's map (#177 eng PR 1, extracted from `WalkDayView`, #170 DS4,
/// DS7): level and north-up in the app's muted style, fitted to the runs
/// with 15% padding and a 300 m floor (the detail preview's minimum), pan
/// and zoom only, no pins, drawing the shared trail (`WalkedTrail`) at the
/// main map's width bands. Past the run cap it draws nothing and says "Zoom
/// in to see your blocks.". VoiceOver reads it as one element with the
/// caller's label and value, and gets Zoom In, Zoom Out and Show Whole Walk
/// (#177 DS6), so the zoom-in line can be acted on without a pinch.
///
/// The camera is the caller's binding: the first runs fit it, later runs
/// keep where the person panned and redraw at the settled camera.
struct WalkRunsMap: View {
    /// `nil` until the runs are built; the map ground shows meanwhile.
    let runs: [WalkedRun]?
    @Binding var position: MapCameraPosition
    let accessibilityLabel: String
    let accessibilityValue: String
    @State private var index: WalkedRunIndex?
    @State private var display = WalkedOverlayDisplay(visible: .runs([]), lineWidth: WalkedOverlay.widthBands[0].width)
    /// The last settled camera region, for a reload's redraw and the zoom
    /// actions.
    @State private var settledRegion: MKCoordinateRegion?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// The detail preview's camera floor (#150 DS1), as the fitted span.
    static let minimumSpanMeters = BodegaDetailMapPreview.cameraDistance
    /// 15% of the runs' extent on each side.
    static let padding = 0.15

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let index {
                Map(position: $position, interactionModes: [.pan, .zoom]) {
                    if case .runs(let runs) = display.visible {
                        WalkedTrail(
                            runs: runs,
                            lineWidth: display.lineWidth,
                            isContrastIncreased: colorSchemeContrast == .increased
                        )
                    }
                }
                .mapStyle(POIFilter.wayfindingOnly.mapStyle(elevation: .flat))
                .onMapCameraChange(frequency: .onEnd) { context in
                    settledRegion = context.region
                    settle(index: index, region: context.region)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if display.visible == .overCap {
                Text(AppCopy.zoomInForBlocksTitle.copy.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityActions {
            ForEach(CameraAction.allCases, id: \.self) { action in
                Button(action.name) { perform(action) }
            }
        }
        .onChange(of: runs, initial: true) { _, runs in
            guard let runs else { return }
            let reloaded = WalkedRunIndex(runs: runs)
            if index == nil {
                position = .region(Self.fittedRegion(runs))
            } else if let settledRegion {
                settle(index: reloaded, region: settledRegion)
            }
            index = reloaded
        }
    }

    /// The VoiceOver actions (DS6), in the order VoiceOver offers them.
    enum CameraAction: CaseIterable {
        case zoomIn, zoomOut, showWholeWalk

        var name: String {
            switch self {
            case .zoomIn: AppCopy.ShareWalk.zoomIn.copy.text
            case .zoomOut: AppCopy.ShareWalk.zoomOut.copy.text
            case .showWholeWalk: AppCopy.ShareWalk.showWholeWalk.copy.text
            }
        }

        /// The region the action moves to from the settled one: half or
        /// twice the span about the same centre, or the runs' fitted region.
        func region(from settled: MKCoordinateRegion, runs: [WalkedRun]) -> MKCoordinateRegion {
            switch self {
            case .zoomIn: WalkRunsMap.scaled(settled, by: 0.5)
            case .zoomOut: WalkRunsMap.scaled(settled, by: 2)
            case .showWholeWalk: WalkRunsMap.fittedRegion(runs)
            }
        }
    }

    private func perform(_ action: CameraAction) {
        let runs = index?.runs ?? runs ?? []
        let settled = settledRegion ?? Self.fittedRegion(runs)
        withAnimation(.easeInOut(duration: 0.3)) {
            position = .region(action.region(from: settled, runs: runs))
        }
    }

    /// Width band and run cap for the settled camera, as the main map does.
    private func settle(index: WalkedRunIndex, region: MKCoordinateRegion) {
        var next = display
        let changed = next.refresh(
            index: index,
            showsOverlay: true,
            region: WalkedRegion(region),
            visibleHeightMeters: region.span.latitudeDelta * StreetGrid.metersPerDegreeLatitude,
            isCameraMoving: false
        )
        if changed { display = next }
    }

    /// `region` with its span times `factor`, about the same centre, kept
    /// inside the spans MapKit accepts.
    static func scaled(_ region: MKCoordinateRegion, by factor: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(
                latitudeDelta: min(region.span.latitudeDelta * factor, 90),
                longitudeDelta: min(region.span.longitudeDelta * factor, 180)
            )
        )
    }

    /// The region around every run, padded 15% a side, never under 300 m
    /// across either way. New York's centre when there are no runs. The
    /// shared picture frames its snapshot with the same rule.
    static func fittedRegion(_ runs: [WalkedRun]) -> MKCoordinateRegion {
        guard let first = runs.first else { return MapScreenView.newYorkCityDefault }
        var minLatitude = first.minLatitude, maxLatitude = first.maxLatitude
        var minLongitude = first.minLongitude, maxLongitude = first.maxLongitude
        for run in runs.dropFirst() {
            minLatitude = min(minLatitude, run.minLatitude)
            maxLatitude = max(maxLatitude, run.maxLatitude)
            minLongitude = min(minLongitude, run.minLongitude)
            maxLongitude = max(maxLongitude, run.maxLongitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let metersPerDegreeLongitude = cos(center.latitude * .pi / 180) * StreetGrid.metersPerDegreeLongitudeAtEquator
        let scale = 1 + 2 * padding
        let floorLatitude = minimumSpanMeters / StreetGrid.metersPerDegreeLatitude
        let floorLongitude = minimumSpanMeters / metersPerDegreeLongitude
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * scale, floorLatitude),
                longitudeDelta: max((maxLongitude - minLongitude) * scale, floorLongitude)
            )
        )
    }
}
