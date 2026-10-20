import SwiftUI

// Read-only pieces of `BodegaDetailView` (data points, hours, a review row,
// the button-row layout), split out to keep that file under SwiftLint's
// file_length limit. Internal rather than `private` only because they live
// in a separate file.

struct DataPointsSection: View {
    let bodega: Bodega

    /// The caption is the same `AppCopy` label onboarding uses for the
    /// amenity, so the two screens never drift ("Hot Food" in both).
    private struct DataPoint {
        let label: AppCopy
        let systemImage: String
        let isPresent: Bool
    }

    private var points: [DataPoint] {
        [
            DataPoint(label: .onboardingCatLabel, systemImage: "cat", isPresent: bodega.hasCat),
            DataPoint(label: .onboardingHotFoodLabel, systemImage: "flame", isPresent: bodega.servesHotFood),
            DataPoint(label: .onboardingCigarettesLabel, systemImage: "smoke", isPresent: bodega.sellsCigarettes),
            DataPoint(label: .onboardingBeerLabel, systemImage: "mug", isPresent: bodega.sellsBeer),
            DataPoint(label: .onboardingLottoLabel, systemImage: "ticket", isPresent: bodega.sellsLotto)
        ]
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Five icon-over-caption columns while they fit at their ideal widths;
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

    /// Presence is visual only (opacity), so the symbol is hidden from
    /// VoiceOver and the caption carries a Yes/No value instead; before
    /// this every amenity read as present.
    private func icon(for point: DataPoint) -> some View {
        Image(systemName: point.systemImage)
            .foregroundStyle(point.isPresent ? .primary : .secondary)
            .opacity(point.isPresent ? 1 : 0.3)
            .accessibilityHidden(true)
    }

    private func caption(for point: DataPoint) -> some View {
        Text(point.label.copy.text)
            .font(.caption2)
            .foregroundStyle(.secondary)
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
            ForEach(orderedDays, id: \.label) { day in
                HStack {
                    // Never truncate/wrap the day at large Dynamic Type sizes;
                    // kept in step with `DayHoursRow` in AddBodegaView.
                    Text(day.label)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 40, alignment: .leading)
                    Text(describe(day.dayHours))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    private func describe(_ dayHours: BodegaHours.DayHours?) -> String {
        guard let dayHours, !dayHours.isClosed else { return "Closed" }
        return "\(dayHours.open) – \(dayHours.close)"
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
            .foregroundStyle(.secondary)
    }
}
