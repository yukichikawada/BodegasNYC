import SwiftUI

// Read-only sections of `BodegaDetailView` that render straight off the
// `Bodega` value (data points, hours), split out to keep that file under
// SwiftLint's file_length limit. Internal rather than `private` only because
// they now live in a separate file.

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

    var body: some View {
        HStack(spacing: 16) {
            ForEach(points, id: \.label) { point in
                VStack(spacing: 4) {
                    Image(systemName: point.systemImage)
                        .foregroundStyle(point.isPresent ? .primary : .secondary)
                        .opacity(point.isPresent ? 1 : 0.3)
                    Text(point.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
