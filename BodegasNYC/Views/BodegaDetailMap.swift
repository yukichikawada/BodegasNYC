import MapKit
import SwiftUI

/// The detail's map group (#150, design DS3): the map preview, then the
/// action row (Directions, Show on Map), then the "Maps didn't open." line
/// when the hand-off failed. One 12pt group inside the page's 20pt stack,
/// between the header and the data points.
struct BodegaDetailMapSection: View {
    /// The detail's bodega as it is now (`viewModel.bodega`), so a name edit
    /// reaches Directions and Show on Map. Edit never moves a pin.
    let bodega: Bodega
    let onShowOnMap: () -> Void
    @State private var directions: BodegaDirections

    init(bodega: Bodega, telemetry: Telemetry, onShowOnMap: @escaping () -> Void) {
        self.bodega = bodega
        self.onShowOnMap = onShowOnMap
        _directions = State(initialValue: BodegaDirections(telemetry: telemetry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodegaDetailMapPreview(bodega: bodega, onTap: onShowOnMap)
            // Directions first and prominent: the page's one primary action
            // (DS3, DS5). Default control size, like the page's other rows (DS11).
            DetailButtonRow {
                Button(AppCopy.directionsAction.copy.text, systemImage: "arrow.triangle.turn.up.right.diamond") {
                    directions.open(bodega)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(AppCopy.directionsHint.copy.text)
                Button(AppCopy.showOnMapAction.copy.text, systemImage: "map", action: onShowOnMap)
                    .buttonStyle(.bordered)
                    .accessibilityHint(AppCopy.detailMapHint.copy.text)
            }
            // The page's load-failed idiom (DS10): consequence copy, no alert,
            // no red. Cleared by the next Directions tap.
            if directions.didNotOpen {
                Text(AppCopy.mapsDidNotOpenBody.copy.text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// A live, non-interactive map of the bodega's block (#150 R1, DS1, DS2):
/// the block and both nearest cross streets, north up and level, the main
/// map's POI exclusions, the pin centred. A plain-button alias of Show on Map
/// (DS8): no chevron, pill or border.
///
/// The ground under the tiles is the grouped surface, so while the tiles
/// load, or offline, the user sees a grey panel with the pin and nothing
/// shifts (fixed 160pt). No spinner, no failure copy. The `Map` keeps its
/// accessibility children (Apple's Legal link); the tap target stops above
/// the attribution band so the link stays tappable.
struct BodegaDetailMapPreview: View {
    static let height: CGFloat = 160
    /// DESIGN.md Shapes `{rounded.md}`, as the gallery thumbnails.
    static let cornerRadius: CGFloat = 12
    /// DS1: close enough that the two nearest cross streets are named on a
    /// 375 pt phone at default type. Tuned on the iPhone SE (3rd generation)
    /// simulator (iOS 26.5, #150): at the reviewed ~400 m the avenue at an
    /// East Village corner went unlabelled; at 300 m it and the street were
    /// both named, as were Hudson, Barrow and Morton in the West Village.
    static let cameraDistance: CLLocationDistance = 300
    /// The Apple Maps logo and Legal link's row at the bottom of the map.
    static let attributionBand: CGFloat = 24
    /// The UI test's handle (the label "Map" is also the Map/List control's).
    static let accessibilityID = "bodegaDetail.mapPreview"

    let bodega: Bodega
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            Map(
                initialPosition: .camera(
                    MapCamera(
                        centerCoordinate: bodega.coordinate.clLocationCoordinate,
                        distance: Self.cameraDistance,
                        heading: 0,
                        pitch: 0
                    )
                ),
                interactionModes: []
            )
            // Its 300 m camera is block zoom: muted, wayfinding only (#154 DS8).
            .mapStyle(POIFilter.wayfindingOnly.mapStyle)
            // The pin is the map's centre, drawn over it rather than as an
            // annotation so it shows before the tiles and never offers
            // VoiceOver a second "<Name>" button.
            BodegaPinView(bodega: bodega, isSelected: false, phase: .atRest)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(alignment: .top) {
            Button(action: onTap) {
                Color.clear
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(height: Self.height - Self.attributionBand)
            .accessibilityLabel(AppCopy.detailMapLabel.copy.text)
            .accessibilityHint(AppCopy.detailMapHint.copy.text)
            .accessibilityIdentifier(Self.accessibilityID)
            .accessibilitySortPriority(1)
        }
    }
}

/// The Apple Maps hand-off (#150 spec D2): walking directions to the pin's
/// coordinate, the destination named with the bodega's name. Coordinates,
/// not the address: the pin is the crowd-verified location and some
/// bodegas have no address. Needs no location permission and no sign-in.
@MainActor
@Observable
final class BodegaDirections {
    /// Walking, always (spec D2).
    static let launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]

    /// Whether the last tap failed to open Maps (DS10).
    private(set) var didNotOpen = false

    @ObservationIgnored private let telemetry: Telemetry
    @ObservationIgnored private let openInMaps: (MKMapItem) -> Bool
    @ObservationIgnored private let announce: (String) -> Void

    init(
        telemetry: Telemetry,
        openInMaps: @escaping (MKMapItem) -> Bool = { $0.openInMaps(launchOptions: BodegaDirections.launchOptions) },
        announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.telemetry = telemetry
        self.openInMaps = openInMaps
        self.announce = announce
    }

    /// `MKMapItem(location:address:)` is the iOS 26 initializer
    /// (`init(placemark:)` is deprecated there).
    static func makeMapItem(for bodega: Bodega) -> MKMapItem {
        let coordinate = bodega.coordinate
        let item = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil
        )
        item.name = bodega.name
        return item
    }

    /// The Directions tap: clears the failure line, opens Maps, and, when
    /// that returns false, shows and announces the line and records the
    /// failure (R4).
    func open(_ bodega: Bodega) {
        didNotOpen = false
        telemetry.capture(.directionsOpened)
        guard !openInMaps(Self.makeMapItem(for: bodega)) else { return }
        didNotOpen = true
        telemetry.record(MapsHandOffError.didNotOpen, context: "directions.open")
        announce(AppCopy.mapsDidNotOpenBody.copy.text)
    }

    /// `openInMaps` returned false (a map item Maps could not take).
    enum MapsHandOffError: Error {
        case didNotOpen
    }
}
