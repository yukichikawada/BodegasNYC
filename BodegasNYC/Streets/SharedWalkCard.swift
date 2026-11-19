import CoreText
import MapKit
import UIKit

/// A map snapshot and how to place a coordinate on it. `@unchecked
/// Sendable`: it is made and read on the main actor only, and its image and
/// snapshot are never mutated.
struct WalkMapSnapshot: @unchecked Sendable {
    let image: UIImage
    /// The point, in the image's own points, where a coordinate falls.
    let point: (CLLocationCoordinate2D) -> CGPoint
}

/// Makes the picture's map (#177 PR 1). A protocol so tests and the UI-test
/// fixtures stub it: they have no network, and MapKit's tiles are not
/// what they check.
@MainActor
protocol WalkMapSnapshotting: Sendable {
    /// A dark, flat, north-up snapshot of `region` at `size` points, 3x.
    /// Throws when MapKit fails; may honour cancellation.
    func snapshot(region: MKCoordinateRegion, size: CGSize) async throws -> WalkMapSnapshot
}

/// The picture that is shared (#177 design DS2, DS3): 1080 x 1350 px (360
/// x 450 pt at 3x), always dark, whatever the sender's appearance, Dynamic
/// Type or Increase Contrast, because it is made for other people.
///
/// On top, the dark muted map, flat and north-up with the wayfinding points
/// of interest, framed like `WalkRunsMap` (`fittedRegion`), and every walked
/// block as a solid `walked` dark cyan line (#5AE3FF), round caps and joins,
/// 5 pt when the fitted height is 2 km or less, else 3 pt, with no run cap.
/// Below it an opaque #1C1C1E band, 16 pt inset: "38 blocks" in the display
/// register at 34 pt, white, tabular digits; "6 new · 2.1 miles" at 17 pt
/// white; the dates leading and "My Bodegas" trailing at 17 pt #98989F; and,
/// when a day in range is an estimate, the estimate line in #98989F (two
/// lines at 17 pt), the band growing from 108 pt by that line's height as
/// the map gives up the height. Lines start at the 16 pt top inset. No card,
/// radius, shadow, gradient or icon.
///
/// A snapshot that fails or takes over 5 s is a failure, never a partial
/// picture (design state table).
enum SharedWalkCard {
    /// The picture in points, drawn at `scale`.
    static let size = CGSize(width: 360, height: 450)
    static let scale: CGFloat = 3
    static let snapshotTimeout: Duration = .seconds(5)
    /// Text inset from the band's edges.
    static let inset: CGFloat = 16
    /// The app's name on the picture (DS3, a recorded DESIGN.md exception
    /// for this exported image only); kept out of `AppCopy`, whose strings
    /// never name the app.
    static let appName = "My Bodegas"

    static let trailColor = UIColor(red: 0x5A / 255, green: 0xE3 / 255, blue: 0xFF / 255, alpha: 1)
    static let bandColor = UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    static let mutedTextColor = UIColor(red: 0x98 / 255, green: 0x98 / 255, blue: 0x9F / 255, alpha: 1)

    /// The bottom-leading corner of the map where MapKit draws its
    /// attribution on a snapshot; the trail is clipped out of it so it
    /// never covers the attribution.
    static let attributionClearance = CGSize(width: 96, height: 24)

    enum Result {
        case picture(SharedWalkPicture)
        case failed
    }

    /// The band without the estimate line (DS2).
    static let baseBandHeight: CGFloat = 108

    /// 108 pt, or with the estimate line 108 pt plus the height that line
    /// takes at 17 pt across the text width (it wraps to two lines).
    static func bandHeight(isEstimate: Bool) -> CGFloat {
        guard isEstimate else { return baseBandHeight }
        return baseBandHeight + textHeight(estimateText, width: size.width - 2 * inset)
    }

    static var estimateText: NSAttributedString {
        NSAttributedString(
            string: AppCopy.ShareWalk.estimate.copy.text,
            attributes: [.font: bodyFont, .foregroundColor: mutedTextColor]
        )
    }

    static let textOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// The whole-point height `text` takes wrapped at `width`.
    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let bounds = CGSize(width: width, height: .greatestFiniteMagnitude)
        return ceil(text.boundingRect(with: bounds, options: textOptions, context: nil).height)
    }

    static func mapSize(isEstimate: Bool) -> CGSize {
        CGSize(width: size.width, height: size.height - bandHeight(isEstimate: isEstimate))
    }

    /// The trail's width (DS2): 5 pt up to 2 km of fitted height, else 3 pt.
    static func trailWidth(for region: MKCoordinateRegion) -> CGFloat {
        region.span.latitudeDelta * StreetGrid.metersPerDegreeLatitude <= 2_000 ? 5 : 3
    }

    /// Snapshots the map for `runs` and draws the picture of `walk`, or
    /// `.failed` when the snapshot fails or takes longer than `timeout`.
    static func make(
        walk: SharedWalk,
        runs: [WalkedRun],
        snapshotter: any WalkMapSnapshotting,
        timeout: Duration = snapshotTimeout
    ) async -> Result {
        let region = WalkRunsMap.fittedRegion(runs)
        let mapSize = mapSize(isEstimate: walk.isEstimate)
        guard let snapshot = await snapshot(region: region, size: mapSize, with: snapshotter, timeout: timeout),
              let picture = render(walk: walk, runs: runs, snapshot: snapshot, trailWidth: trailWidth(for: region))
        else { return .failed }
        return .picture(picture)
    }

    /// The snapshot, or `nil` on a failure or past `timeout`. The timeout
    /// does not wait for a snapshotter that ignores cancellation.
    static func snapshot(
        region: MKCoordinateRegion,
        size: CGSize,
        with snapshotter: any WalkMapSnapshotting,
        timeout: Duration
    ) async -> WalkMapSnapshot? {
        await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            let work = Task { @MainActor in
                once.resume(try? await snapshotter.snapshot(region: region, size: size))
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(nil)
                work.cancel()
            }
        }
    }

    /// Draws the picture over `snapshot`. `nil` only when PNG encoding fails.
    static func render(
        walk: SharedWalk,
        runs: [WalkedRun],
        snapshot: WalkMapSnapshot,
        trailWidth: CGFloat
    ) -> SharedWalkPicture? {
        let mapSize = mapSize(isEstimate: walk.isEstimate)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        // 8-bit sRGB, so the PNG is the same on every device.
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let mapRect = CGRect(origin: .zero, size: mapSize)
            snapshot.image.draw(in: mapRect)
            drawTrail(runs, on: snapshot, in: mapRect, width: trailWidth, context: context.cgContext)
            let band = CGRect(x: 0, y: mapSize.height, width: size.width, height: size.height - mapSize.height)
            bandColor.setFill()
            context.fill(band)
            drawBand(walk, in: band)
        }
        guard let png = image.pngData() else { return nil }
        return SharedWalkPicture(walk: walk, png: png, image: image)
    }

    private static func drawTrail(
        _ runs: [WalkedRun],
        on snapshot: WalkMapSnapshot,
        in mapRect: CGRect,
        width: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        // Inside the map, and clear of the attribution corner.
        let clearance = CGRect(
            x: mapRect.minX,
            y: mapRect.maxY - attributionClearance.height,
            width: attributionClearance.width,
            height: attributionClearance.height
        )
        let clip = UIBezierPath(rect: mapRect)
        clip.append(UIBezierPath(rect: clearance).reversing())
        clip.addClip()
        let path = UIBezierPath()
        for run in runs {
            let points = WalkedOverlay.simplified(run.coordinates).map {
                snapshot.point(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
            }
            guard let first = points.first else { continue }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        trailColor.setStroke()
        path.stroke()
        context.restoreGState()
    }

    /// The band's lines, stacked from the 16 pt top inset, leading at the
    /// inset; the dates share their line with the app's name, trailing.
    private static func drawBand(_ walk: SharedWalk, in band: CGRect) {
        let width = band.width - 2 * inset
        let white = UIColor.white
        let count = NSAttributedString(
            string: AppCopy.walkDayBlocks(walk.blockCount).text,
            attributes: [.font: displayFont, .foregroundColor: white]
        )
        let counts = NSAttributedString(
            string: AppCopy.sharedWalkPictureCounts(walk),
            attributes: [.font: bodyFont, .foregroundColor: white]
        )
        let dates = NSAttributedString(
            string: AppCopy.sharedWalkDates(first: walk.firstDay, last: walk.lastDay).text,
            attributes: [.font: bodyFont, .foregroundColor: mutedTextColor]
        )
        let name = NSAttributedString(
            string: appName,
            attributes: [.font: bodyFont, .foregroundColor: mutedTextColor]
        )
        let estimate = walk.isEstimate ? estimateText : nil
        let options = textOptions
        func height(_ text: NSAttributedString, _ maxWidth: CGFloat) -> CGFloat {
            textHeight(text, width: maxWidth)
        }
        let nameWidth = ceil(name.size().width)
        let datesWidth = width - nameWidth - 8
        let lines: [CGFloat] = [
            height(count, width), height(counts, width), max(height(dates, datesWidth), height(name, nameWidth))
        ] + (estimate.map { [height($0, width)] } ?? [])
        var top = band.minY + inset
        count.draw(with: CGRect(x: inset, y: top, width: width, height: lines[0]), options: options, context: nil)
        top += lines[0]
        counts.draw(with: CGRect(x: inset, y: top, width: width, height: lines[1]), options: options, context: nil)
        top += lines[1]
        dates.draw(with: CGRect(x: inset, y: top, width: datesWidth, height: lines[2]), options: options, context: nil)
        name.draw(
            with: CGRect(x: band.maxX - inset - nameWidth, y: top, width: nameWidth, height: lines[2]),
            options: options,
            context: nil
        )
        top += lines[2]
        if let estimate {
            let frame = CGRect(x: inset, y: top, width: width, height: lines[3])
            estimate.draw(with: frame, options: options, context: nil)
        }
    }

    /// The display register (D5, `Font.display`) at a fixed 34 pt with
    /// tabular digits: the picture's fixed type, a DESIGN.md exception.
    static var displayFont: UIFont {
        tabular(UIFont.systemFont(ofSize: 34, weight: .heavy, width: .condensed))
    }

    static var bodyFont: UIFont {
        tabular(UIFont.systemFont(ofSize: 17, weight: .regular))
    }

    private static func tabular(_ font: UIFont) -> UIFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector
            ]]
        ])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

/// A made picture: the PNG and the walk it shows, frozen together so Share
/// sends exactly what the preview showed.
struct SharedWalkPicture: Equatable {
    let walk: SharedWalk
    let png: Data
    let image: UIImage

    static func == (lhs: SharedWalkPicture, rhs: SharedWalkPicture) -> Bool {
        lhs.walk == rhs.walk && lhs.png == rhs.png
    }
}

/// Resumes a continuation once, whichever of the snapshot and the timeout
/// finishes first.
private final class OnceResume {
    private var continuation: CheckedContinuation<WalkMapSnapshot?, Never>?

    init(_ continuation: CheckedContinuation<WalkMapSnapshot?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: WalkMapSnapshot?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// MapKit's snapshotter with the picture's look: the dark trait collection,
/// the muted standard configuration with the wayfinding filter (#154 DS8),
/// flat, north-up.
struct MapKitWalkSnapshotter: WalkMapSnapshotting {
    func snapshot(region: MKCoordinateRegion, size: CGSize) async throws -> WalkMapSnapshot {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.traitCollection = UITraitCollection(mutations: { traits in
            traits.userInterfaceStyle = .dark
            traits.displayScale = SharedWalkCard.scale
        })
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = MKPointOfInterestFilter(
            including: BodegaMapViewModel.wayfindingPOICategories
        )
        options.preferredConfiguration = configuration
        let box = SnapshotterBox(MKMapSnapshotter(options: options))
        let snapshot = try await withTaskCancellationHandler {
            try await box.snapshotter.start()
        } onCancel: {
            box.snapshotter.cancel()
        }
        return WalkMapSnapshot(image: snapshot.image) { snapshot.point(for: $0) }
    }
}

/// Lets the cancellation handler reach the snapshotter. `@unchecked
/// Sendable`: `cancel()` is MapKit's documented way to stop a snapshot in
/// flight from anywhere.
nonisolated private final class SnapshotterBox: @unchecked Sendable {
    let snapshotter: MKMapSnapshotter

    init(_ snapshotter: MKMapSnapshotter) {
        self.snapshotter = snapshotter
    }
}
