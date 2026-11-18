import MapKit
import SwiftUI

/// One walked day (#170 design DS4, DS5, DS7, DS8.4): its map and, in a
/// bottom bar on the opaque ground, "14 blocks" with "9 new" in `textMuted`
/// over "1.4 miles". Title "Nov 3, 2025", inline.
///
/// The map is level and north-up in the app's muted style, fitted to the
/// day's runs with 15% padding and a 300 m floor (the detail preview's
/// minimum), pan and zoom only, no pins, drawing the shared trail
/// (`WalkedTrail`) at the main map's width bands. Past the run cap it draws
/// nothing and says "Zoom in to see your blocks.". It keeps a 200 pt
/// minimum height; when the bar leaves less than that (landscape, large
/// type) the page scrolls. VoiceOver reads the map as one element, "Map of
/// this day's walk.", with the counts as its value.
struct WalkDayView: View {
    let day: WalkedDayKey
    let viewModel: StreetsWalkedViewModel
    @State private var index: WalkedRunIndex?
    @State private var position: MapCameraPosition = .automatic
    @State private var display = WalkedOverlayDisplay(visible: .runs([]), lineWidth: WalkedOverlay.widthBands[0].width)
    @State private var barHeight: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let minimumMapHeight: CGFloat = 200
    /// The detail preview's camera floor (#150 DS1), as the fitted span.
    static let minimumSpanMeters = BodegaDetailMapPreview.cameraDistance
    /// 15% of the runs' extent on each side.
    static let padding = 0.15

    var body: some View {
        let summary = viewModel.walksHistory?.summary(for: day)
        let isEstimate = viewModel.walksHistory?.isEstimate(day) ?? false
        GeometryReader { geometry in
            let roomForMap = geometry.size.height - barHeight
            ScrollView {
                VStack(spacing: 0) {
                    map(summary)
                        .frame(height: max(Self.minimumMapHeight, roomForMap))
                    summaryBar(summary, isEstimate: isEstimate)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                }
            }
            .scrollDisabled(roomForMap >= Self.minimumMapHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(AppCopy.walkDayTitle(day).text)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) {
            let runs = await viewModel.walkDayRuns(day)
            position = .region(Self.fittedRegion(runs))
            index = WalkedRunIndex(runs: runs)
        }
    }

    private func map(_ summary: WalkedDaySummary?) -> some View {
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
        .accessibilityLabel(AppCopy.YourWalks.dayMapLabel.copy.text)
        .accessibilityValue(summary.map { AppCopy.walkDaySummary($0).text } ?? "")
    }

    /// Two lines (DS4), stacking at accessibility sizes, and the estimate
    /// line on an estimated day (DS5).
    private func summaryBar(_ summary: WalkedDaySummary?, isEstimate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                layout {
                    Text(AppCopy.walkDayBlocks(summary.walkedIDs.count).text)
                        .foregroundStyle(.primary)
                    if summary.newCount > 0 {
                        Text(AppCopy.walkDayNew(summary.newCount).text)
                            .foregroundStyle(Color.textMuted)
                    }
                }
                .font(.body)
                Text(AppCopy.walkDayDistance(meters: summary.meters).text)
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
            }
            if isEstimate {
                Text(AppCopy.YourWalks.estimates.copy.text)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
                    .padding(.top, 4)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemGroupedBackground))
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

    /// The region around every run, padded 15% a side, never under 300 m
    /// across either way. New York's centre when there are no runs.
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
