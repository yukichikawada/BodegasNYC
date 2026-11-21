import Accessibility
import Charts
import SwiftUI

/// The Progress tab's bars (#188): blocks walked per day, or per week,
/// month or year over long ranges, under the range picker. The heading
/// names the unit ("Blocks per Day", DS9) over a second line that is the
/// legend at rest and the scrubbed bar's counts and dates while a finger is
/// on either chart (DS8), at one height (DS13). Each bar is the day's new
/// blocks in solid `walked` cyan under the blocks walked before, the same
/// cyan at 35% closed by a 1 pt solid outline inside its bounds (DS1);
/// Increase Contrast drops the tint and keeps the outline in the contrast
/// slot. Square corners, no bar dims while scrubbing (DS12).
///
/// The x-domain, ticks, gridlines and today's label are the line chart's
/// (DS4, DS14), and the y labels sit in the same fixed column, so the two
/// plots line up day for day. VoiceOver reads the heading and plot as one
/// adjustable element that steps through every bucket, zeros included,
/// with an Audio Graph (DS17, DS18).
struct WalkDailyBarsChart: View {
    let slice: WalkProgressSlice
    /// The y labels' shared column (DS4, `WalkChartYLabel`).
    let yLabelColumn: [String]
    /// The day index under the finger, shared with the line (eng E1).
    @Binding var selectedDay: Int?
    /// The bucket VoiceOver has stepped to (a position in `buckets`); its
    /// own state, apart from the touch selection; `nil` reads the summary.
    @State private var voiceOverPosition: Int?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let plotHeight: CGFloat = 140
    /// The walked-before tint (DS1, the breadcrumb track's tone).
    static let repeatOpacity = 0.35

    private var bars: WalkDailyBars { slice.bars }
    private var isContrastIncreased: Bool { colorSchemeContrast == .increased }

    var body: some View {
        let selected = selectedDay.map { bars.bar(containing: $0) }
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                header(selected)
                    .padding(.horizontal, 16)
                chart
                    .frame(height: Self.plotHeight)
                    .padding(.horizontal, 16)
                    // Axis labels capped as the line chart's are.
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppCopy.walkBarsChartLabel(bars.unit).text)
            .accessibilityValue(voiceOverValue)
            .accessibilityAddTraits(.isHeader)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: voiceOverPosition = bars.stepped(from: voiceOverPosition, by: 1)
                case .decrement: voiceOverPosition = bars.stepped(from: voiceOverPosition, by: -1)
                @unknown default: break
                }
            }
            .accessibilityChartDescriptor(WalkDailyBarsAudioGraph(bars: bars, xTicks: slice.xTicks))
            .accessibilityIdentifier("yourWalks.progress.bars")
            if bars.unit != .day {
                // DS6: a grouped bar sums its days, repeats included.
                Text(AppCopy.YourWalks.barsFootnote.copy.text)
                    .font(.footnote)
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var voiceOverValue: String {
        guard let voiceOverPosition, bars.buckets.indices.contains(voiceOverPosition) else {
            return AppCopy.walkBarsRestValue(slice).text
        }
        return AppCopy.walkBarSpokenValue(bars.buckets[voiceOverPosition], in: bars).text
    }

    // MARK: Header

    /// The heading over the second line. Every version of the second line
    /// is laid out in one place, the inactive ones hidden, under a hidden
    /// copy of the longest readout the slice can produce (DS13).
    private func header(_ selected: WalkDailyBars.Bar?) -> some View {
        let atRest = selected == nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(AppCopy.walkBarsHeading(bars.unit).text)
                .font(.headline)
                .foregroundStyle(.primary)
            ZStack(alignment: .topLeading) {
                readout(slice.barsReserve).hidden()
                restLine.opacity(atRest ? 1 : 0)
                if let selected {
                    readout(AppCopy.walkBarReadout(selected, in: bars))
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.textMuted)
            .monospacedDigit()
            // At AX5 a wrapping reserve was sized a line taller than it
            // was drawn, leaving a gap over the footer (simulator capture).
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The legend, or the empty range's line in its place (DS11).
    @ViewBuilder private var restLine: some View {
        if let empty = AppCopy.walkBarsEmptyLine(slice) {
            Text(empty.text)
        } else {
            WalkDailyBarsLegend(isContrastIncreased: isContrastIncreased)
        }
    }

    /// Counts then dates: one line joined by the separator, or counts over
    /// dates at accessibility sizes (DS13).
    @ViewBuilder private func readout(_ parts: [String]) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(parts.indices, id: \.self) { Text(parts[$0]) }
            }
        } else {
            Text(parts.joined(separator: AppCopy.walksSeparator))
        }
    }

    // MARK: Plot

    private var chart: some View {
        let ticks = Dictionary(slice.xTicks.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let showsYLabels = AppCopy.walkBarsEmptyLine(slice) == nil
        return Chart {
            // DS12: the rule shows above a bar, never across it. It starts
            // at the bar's top, since the walked-before tint is see-through
            // and a rule drawn behind it still showed (simulator capture).
            // The line chart's Int binding reports the day past the plot's
            // trailing edge (simulator probe), so the rule clamps as the
            // line's point does.
            if let selectedDay, let day = bars.dayIndex(forX: Double(selectedDay)) {
                RuleMark(
                    x: .value("Day", Double(day)),
                    yStart: .value("Blocks", bars.bar(containing: day).total),
                    yEnd: .value("Blocks", bars.yDomain.upperBound)
                )
                    .foregroundStyle(Color.textMuted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(bars.bars) { bar in
                let extent = bars.xExtent(of: bar)
                if bar.new > 0 {
                    RectangleMark(
                        xStart: .value("Day", extent.lowerBound),
                        xEnd: .value("Day", extent.upperBound),
                        yStart: .value("Blocks", 0),
                        yEnd: .value("Blocks", bar.new)
                    )
                    .foregroundStyle(Color.walked)
                }
                if bar.repeated > 0, !isContrastIncreased {
                    RectangleMark(
                        xStart: .value("Day", extent.lowerBound),
                        xEnd: .value("Day", extent.upperBound),
                        yStart: .value("Blocks", bar.new),
                        yEnd: .value("Blocks", bar.total)
                    )
                    .foregroundStyle(Color.walked.opacity(Self.repeatOpacity))
                }
            }
        }
        .chartXScale(domain: slice.xDomain)
        .chartYScale(domain: bars.yDomain)
        .chartXAxis {
            AxisMarks(values: slice.xTicks.map { Double($0.index) }) { value in
                let index = value.as(Double.self).map { Int($0.rounded()) }
                AxisGridLine()
                AxisValueLabel(anchor: WalkProgressChart.labelAnchor(index, lastIndex: slice.lastIndex)) {
                    if let index, let tick = ticks[index] {
                        Text(AppCopy.walkChartAxisLabel(tick.day, style: tick.style).text)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: bars.yTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    WalkChartYLabel(value: value.as(Int.self), column: yLabelColumn)
                        .opacity(showsYLabels ? 1 : 0)
                }
            }
        }
        .chartOverlay { proxy in
            // DS1: Swift Charts has no stroke for a rectangle mark, so the
            // walked-before outlines are drawn here from the plot's own
            // positions, 1 pt inside each segment's bounds.
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let origin = geometry[plotFrame].origin
                    WalkDailyBarsOutlines(rects: outlineRects(proxy))
                        .stroke(Color.walked, lineWidth: 1)
                        .offset(x: origin.x, y: origin.y)
                }
            }
            .allowsHitTesting(false)
        }
        .chartXSelection(value: Binding(
            get: { selectedDay.map(Double.init) },
            // E2: the bars round a continuous x themselves.
            set: { selectedDay = bars.dayIndex(forX: $0) }
        ))
    }

    /// Each walked-before segment's rectangle in plot coordinates.
    private func outlineRects(_ proxy: ChartProxy) -> [CGRect] {
        bars.bars.compactMap { bar in
            guard bar.repeated > 0 else { return nil }
            let extent = bars.xExtent(of: bar)
            guard let left = proxy.position(forX: extent.lowerBound),
                  let right = proxy.position(forX: extent.upperBound),
                  let top = proxy.position(forY: bar.total),
                  let bottom = proxy.position(forY: bar.new)
            else { return nil }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}

/// The walked-before outlines (DS1): each rectangle inset half a point, so
/// a 1 pt stroke lies inside the segment's bounds.
private nonisolated struct WalkDailyBarsOutlines: Shape {
    let rects: [CGRect]

    func path(in _: CGRect) -> Path {
        var path = Path()
        for rect in rects where rect.width > 1 && rect.height > 1 {
            path.addRect(rect.insetBy(dx: 0.5, dy: 0.5))
        }
        return path
    }
}

/// "■ New ▣ Walked Before" (DS15, DS19): 8 pt squares scaled with the
/// text, 4 pt to their labels, 12 pt between items, side by side when they
/// fit, else stacked. Drawn as the bars are; hidden from VoiceOver (the
/// chart element reads its own value).
struct WalkDailyBarsLegend: View {
    let isContrastIncreased: Bool
    @ScaledMetric(relativeTo: .subheadline) private var square: CGFloat = 8

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var items: some View {
        HStack(spacing: 4) {
            Rectangle().fill(Color.walked).frame(width: square, height: square)
            Text(AppCopy.YourWalks.barsLegendNew.copy.text)
        }
        HStack(spacing: 4) {
            Rectangle()
                .fill(isContrastIncreased ? Color.clear : Color.walked.opacity(WalkDailyBarsChart.repeatOpacity))
                .overlay(Rectangle().strokeBorder(Color.walked, lineWidth: 1))
                .frame(width: square, height: square)
            Text(AppCopy.YourWalks.barsLegendWalkedBefore.copy.text)
        }
    }
}

/// A y-axis label in the column both charts share (#188 DS4): the widest
/// of the two charts' top labels laid out hidden under the visible one, so
/// both plots end at the same x whatever their numbers.
struct WalkChartYLabel: View {
    let value: Int?
    let column: [String]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(column.indices, id: \.self) { Text(column[$0]).hidden() }
            if let value { Text(AppCopy.groupedCount(value)) }
        }
        .monospacedDigit()
    }
}

/// The bars' Audio Graph (DS17): one point per bucket of the range, zeros
/// included, x as the bucket's first day, y in blocks; not continuous.
private struct WalkDailyBarsAudioGraph: AXChartDescriptorRepresentable {
    let bars: WalkDailyBars
    let xTicks: [WalkProgressSlice.Tick]

    func makeChartDescriptor() -> AXChartDescriptor {
        let lastIndex = max(0, bars.dayCount - 1)
        let xAxis = AXNumericDataAxisDescriptor(
            title: AppCopy.YourWalks.chartDayAxis.copy.text,
            range: 0 ... Double(max(1, lastIndex)),
            gridlinePositions: xTicks.map { Double($0.index) }
        ) { [bars] value in
            AppCopy.walkBarSpokenDates(bars.bar(containing: Int(value.rounded())), in: bars)
        }
        let domain = bars.yDomain
        let yAxis = AXNumericDataAxisDescriptor(
            title: AppCopy.YourWalks.chartBlocksAxis.copy.text,
            range: Double(domain.lowerBound) ... Double(domain.upperBound),
            gridlinePositions: bars.yTicks.map(Double.init)
        ) { AppCopy.walkDayBlocks(Int($0.rounded())).text }
        let name = AppCopy.walkBarsHeading(bars.unit).text
        let series = AXDataSeriesDescriptor(
            name: name,
            isContinuous: false,
            dataPoints: bars.buckets.map { AXDataPoint(x: Double($0.startIndex), y: Double($0.total)) }
        )
        return AXChartDescriptor(
            title: name, summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series]
        )
    }
}
