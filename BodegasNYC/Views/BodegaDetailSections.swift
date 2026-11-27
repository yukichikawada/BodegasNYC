import SwiftUI

// Read-only pieces of `BodegaDetailView` (hours, a review row, the
// button-row layout; the data points have their own file), split out to
// keep that file under SwiftLint's file_length limit. Internal rather than
// `private` only because they live in a separate file.

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

struct RatingSummaryView: View {
    let averageRating: Double?
    let reviewCount: Int

    /// Renders nothing without a rating (design DD9): the reviews section
    /// owns the empty state, so "No reviews yet." isn't said twice.
    var body: some View {
        if let averageRating {
            HStack(spacing: 6) {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
                Text(String(format: "%.1f", averageRating))
                    .font(.headline)
                Text("(\(reviewCount) review\(reviewCount == 1 ? "" : "s"))")
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
            }
        }
    }
}

/// A detail section's empty state (design DD9): quiet title and body,
/// leading, no symbol, inside the section's own stack under its header and
/// actions.
struct SectionEmptyState: View {
    let title: AppCopy
    let message: AppCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.copy.text)
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
            Text(message.copy.text)
                .font(.footnote)
                .foregroundStyle(Color.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ReviewsSection: View {
    let reviews: [Review]
    let hasCat: Bool
    let currentUserID: UUID?
    let onFlag: (Review) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews").font(.headline)
            if reviews.isEmpty {
                let empty = AppCopy.noReviews(hasCat: hasCat)
                SectionEmptyState(title: empty.title, message: empty.body)
            } else {
                ForEach(reviews) { review in
                    // No flag option on your own review — edit it instead
                    // (the "Edit Your Review" button below).
                    if review.authorId == currentUserID {
                        ReviewRow(review: review)
                    } else {
                        ReviewRow(review: review)
                            .contextMenu {
                                Button("Flag Review", systemImage: "flag") { onFlag(review) }
                            }
                    }
                }
            }
        }
    }
}
