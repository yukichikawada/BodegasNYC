import SwiftUI

// Read-only pieces of `BodegaDetailView` (data points, hours, a review row,
// the button-row layout), split out to keep that file under SwiftLint's
// file_length limit. Internal rather than `private` only because they live
// in a separate file.

struct DataPointsSection: View {
    let bodega: Bodega

    private struct DataPoint {
        let label: String
        let systemImage: String
        let isPresent: Bool
    }

    private var points: [DataPoint] {
        [
            DataPoint(label: "Cat", systemImage: "cat", isPresent: bodega.hasCat),
            DataPoint(label: "Hot food", systemImage: "flame", isPresent: bodega.servesHotFood),
            DataPoint(label: "Cigarettes", systemImage: "smoke", isPresent: bodega.sellsCigarettes),
            DataPoint(label: "Beer", systemImage: "mug", isPresent: bodega.sellsBeer),
            DataPoint(label: "Lotto", systemImage: "ticket", isPresent: bodega.sellsLotto)
        ]
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Five icon-over-caption columns while they fit at their ideal widths;
    /// otherwise, and always from `.accessibility1` up (DD16, the same
    /// threshold as the map card), one leading icon-and-caption row per
    /// point, so no caption is squeezed into broken lines ("Ho/t/foo/d")
    /// and nothing pushes the column past the page inset (#70).
    var body: some View {
        if MapBottomCard.usesStackedLayout(for: dynamicTypeSize) {
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

    private func icon(for point: DataPoint) -> some View {
        Image(systemName: point.systemImage)
            .foregroundStyle(point.isPresent ? .primary : .secondary)
            .opacity(point.isPresent ? 1 : 0.3)
    }

    private func caption(for point: DataPoint) -> some View {
        Text(point.label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// The detail screen's button rows (the photos header, the review/flag
/// row): side by side normally, a leading `VStack` with 12pt grouping from
/// `.accessibility1` up (DD16), so accessibility-size labels wrap inside
/// the 16pt page inset instead of widening the content column (#70).
struct DetailButtonRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content

    var body: some View {
        let layout = MapBottomCard.usesStackedLayout(for: dynamicTypeSize)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout { content }
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
