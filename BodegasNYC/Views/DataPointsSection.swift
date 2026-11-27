import SwiftUI

/// The detail screen's seven data points (#70, #95 D9, #141, #194, #196).
/// Split out of `BodegaDetailSections.swift` when #196 added the grid form.
struct DataPointsSection: View {
    let bodega: Bodega

    /// The caption is the amenity's one `AppCopy` label
    /// (`BodegaFilter.Amenity.caption`), shared by onboarding, the detail
    /// screen and the Add/Edit form, so they never drift ("Hot Food" in all).
    struct DataPoint {
        let label: AppCopy
        let systemImage: String
        let isPresent: Bool

        /// Present: symbol and caption in `.primary`. Absent: the same symbol
        /// and a struck-through caption in `textMuted`, never dimmed by
        /// opacity (#95 design D9). D9 asks for the symbol's `.slash` variant
        /// where one exists; none of the seven has one in iOS 26 (`cat.slash`,
        /// `flame.slash`, `cross.slash`, `mug.slash`, `ticket.slash`,
        /// `banknote.slash` and `toilet.slash` are not SF Symbols), so the
        /// strikethrough is the shape cue for all.
        var foreground: Color { isPresent ? .primary : .textMuted }
        var strikesCaption: Bool { !isPresent }
    }

    private var points: [DataPoint] { Self.points(for: bodega) }

    /// One point per `BodegaFilter.Amenity`, in its order (#141 eng D5).
    static func points(for bodega: Bodega) -> [DataPoint] {
        BodegaFilter.Amenity.allCases.map { amenity in
            DataPoint(
                label: amenity.caption,
                systemImage: amenity.systemImage,
                isPresent: amenity.isSatisfied(by: bodega)
            )
        }
    }

    /// The grid form's cells per row (#196 DS2): four over three.
    static let gridColumnCount = 4

    /// The points split into the grid's rows, in amenity order, row by row:
    /// Cat, Hot Food, Nicotine, Beer, then Lotto, ATM, Bathroom. The last
    /// row is short; its missing cells get no placeholder view (DS2), and an
    /// eighth point fills row two, column four (DS11).
    static func gridRows(_ points: [DataPoint]) -> [[DataPoint]] {
        stride(from: 0, to: points.count, by: gridColumnCount).map { start in
            Array(points[start..<min(start + gridColumnCount, points.count)])
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The symbol's slot in the row and the grid (#196 DS7): one height for
    /// all seven, so captions share a baseline whatever each symbol's own
    /// height (toilet is the tallest, ticket and banknote the shortest).
    /// Scaled with `.caption2`; 24 pt at Large holds the tallest symbol
    /// at the body size the symbols render at, and `.caption2` grows faster
    /// than body from Large to xxxLarge, so the slot keeps holding it.
    @ScaledMetric(relativeTo: .caption2) private var symbolSlotHeight: CGFloat = 24

    /// The first form that fits the width wins (#196 DS1): one row of seven
    /// icon-over-caption columns, else a grid of four over three, else one
    /// leading icon-and-caption row per point. Accessibility sizes always
    /// get the rows (DD16, the map card's threshold). Row and grid captions
    /// never wrap, shrink or truncate and neither form holds a flexible
    /// spacer or frame, so `ViewThatFits` measures their real width and
    /// falls through instead of squeezing a caption into broken lines
    /// ("Ho/t/foo/d", #70) or past the page inset (DS6). No animation
    /// between forms (DS10).
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                row
                grid
                stacked
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(points, id: \.label) { point in
                cell(for: point)
            }
        }
    }

    /// Columns as wide as their widest cell (equal quarters would not fit
    /// "Bathroom" at xxxLarge on a 375 pt phone, DS4), cells centred in
    /// their column, the grid at its natural width on the leading inset
    /// (DS3). 16 pt between columns as in the row, 12 pt between the rows as
    /// in the stacked form (DS5).
    private var grid: some View {
        Grid(alignment: .top, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(Array(Self.gridRows(points).enumerated()), id: \.offset) { _, rowPoints in
                GridRow {
                    ForEach(rowPoints, id: \.label) { point in
                        cell(for: point)
                    }
                }
            }
        }
    }

    /// One symbol over its caption, for the row and the grid.
    private func cell(for point: DataPoint) -> some View {
        VStack(spacing: 4) {
            icon(for: point)
                .frame(height: symbolSlotHeight)
            caption(for: point)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// A two-column grid so the captions share one leading edge whatever
    /// each symbol's width; symbols centre in their column. Captions here
    /// may wrap, as before.
    private var stacked: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
            ForEach(points, id: \.label) { point in
                GridRow {
                    icon(for: point)
                        .gridColumnAlignment(.center)
                    caption(for: point)
                }
            }
        }
    }

    /// Presence is visual only (color and the caption's strikethrough), so
    /// the symbol is hidden from VoiceOver and the caption carries a Yes/No
    /// value instead; before this every amenity read as present.
    private func icon(for point: DataPoint) -> some View {
        Image(systemName: point.systemImage)
            .foregroundStyle(point.foreground)
            .accessibilityHidden(true)
    }

    private func caption(for point: DataPoint) -> some View {
        Text(point.label.copy.text)
            .font(.caption2)
            .strikethrough(point.strikesCaption)
            .foregroundStyle(point.foreground)
            .accessibilityValue(
                (point.isPresent ? AppCopy.dataPointPresentValue : AppCopy.dataPointAbsentValue).copy.text
            )
    }
}
