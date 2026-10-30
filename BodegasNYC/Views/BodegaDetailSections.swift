import SwiftUI

// Read-only pieces of `BodegaDetailView` (data points, hours, a review row,
// the button-row layout), split out to keep that file under SwiftLint's
// file_length limit. Internal rather than `private` only because they live
// in a separate file.

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
        /// where one exists; none of the six has one in iOS 26 (`cat.slash`,
        /// `flame.slash`, `cross.slash`, `mug.slash`, `ticket.slash` and
        /// `banknote.slash` are not SF Symbols), so the strikethrough is the
        /// shape cue for all.
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Six icon-over-caption columns while they fit at their ideal widths
    /// (through xxxLarge on a 402 pt phone, through xxLarge on 375 pt);
    /// otherwise, and always at the accessibility sizes (DD16, the same
    /// threshold as the map card), one leading icon-and-caption row per
    /// point, so no caption is squeezed into broken lines ("Ho/t/foo/d")
    /// and nothing pushes the column past the page inset (#70).
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                columns
                stacked
            }
        }
    }

    private var columns: some View {
        HStack(spacing: 16) {
            ForEach(points, id: \.label) { point in
                VStack(spacing: 4) {
                    icon(for: point)
                    caption(for: point)
                }
            }
        }
    }

    /// A two-column grid so the captions share one leading edge whatever
    /// each symbol's width; symbols centre in their column.
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

/// The detail screen's button rows: the review/flag pair, and the photos
/// header, where a title leads and its action trails. Side by side while
/// everything fits at its ideal width, otherwise (and always at the
/// accessibility sizes, DD16) a leading `VStack` with 12pt grouping, so a
/// label never wraps mid-phrase inside its button and nothing widens the
/// content column past the 16pt page inset (#70).
///
/// Side by side, the buttons keep their ideal width (`fixedSize`): an
/// `HStack` proposes an equal split to its children, which wraps a button
/// that would have fit, and `ViewThatFits` had already judged the row by
/// ideal widths. Stacked, they may wrap.
struct DetailButtonRow<Title: View, Buttons: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let title: Title?
    private let buttons: Buttons

    init(@ViewBuilder buttons: () -> Buttons) where Title == EmptyView {
        title = nil
        self.buttons = buttons()
    }

    init(@ViewBuilder title: () -> Title, @ViewBuilder buttons: () -> Buttons) {
        self.title = title()
        self.buttons = buttons()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        }
    }

    private var sideBySide: some View {
        HStack(spacing: 12) {
            if let title {
                title.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) { buttons }
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                title
            }
            buttons
        }
    }
}

struct HoursSection: View {
    let hours: BodegaHours

    private var orderedDays: [(label: String, dayHours: BodegaHours.DayHours?)] {
        [
            ("Mon", hours.mon), ("Tue", hours.tue), ("Wed", hours.wed), ("Thu", hours.thu),
            ("Fri", hours.fri), ("Sat", hours.sat), ("Sun", hours.sun)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hours").font(.headline)
            // A two-column grid sizes the day column to its widest label, so
            // the times share one leading edge at every Dynamic Type size; a
            // fixed minimum width was narrower than "Wed" at accessibility
            // sizes and staggered the times (#77).
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(orderedDays, id: \.label) { day in
                    GridRow {
                        DayLabel(text: day.label)
                            .gridColumnAlignment(.leading)
                        Text(describe(day.dayHours))
                            .monospacedDigit()
                            .foregroundStyle(Color.textMuted)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func describe(_ dayHours: BodegaHours.DayHours?) -> String {
        guard let dayHours, !dayHours.isClosed else { return "Closed" }
        return "\(dayHours.open) – \(dayHours.close)"
    }
}

/// A weekday label ("Mon") that never truncates or wraps at large Dynamic
/// Type sizes. Shared by `HoursSection` here and `DayHoursRow` in
/// AddBodegaView so the two hours lists do not drift.
struct DayLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct ReviewRow: View {
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The date drops under the stars when both don't fit on one
            // line, instead of breaking mid-word ("Oc-to-ber") at AX sizes (#70).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { stars; date }
                VStack(alignment: .leading, spacing: 4) { stars; date }
            }
            if let body = review.body {
                Text(body).font(.body)
            }
        }
    }

    private var stars: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < review.rating ? "star.fill" : "star")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
        }
    }

    private var date: some View {
        Text(review.createdAt, style: .date)
            .font(.caption)
            .foregroundStyle(Color.textMuted)
    }
}
