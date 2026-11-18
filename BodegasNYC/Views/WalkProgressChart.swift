import Accessibility
import Charts
import SwiftUI

/// Your Walks' Progress tab (#170 PR 2, design DS6, DS8.2, DS8.6): the
/// chart with its header, then the range picker under it, then the sheet's
/// footer. The states follow the Calendar's (`YourWalksContent`): a first
/// read shows "Finding your walks…" under the title over the chart's empty
/// room; history with no walked day shows the flat line and "No blocks
/// counted yet."; the no-grid states never reach this view. A range change
/// is the app's 0.25 s opacity change, which is also what Reduce Motion
/// gets (DS8.6).
struct WalkProgressView: View {
    let content: YourWalksContent
    let progress: WalkProgress?
    @Binding var range: WalkProgressRange

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    if let progress {
                        WalkProgressChart(slice: progress.slice(range), headline: progress.headline)
                            .id(range)
                            .transition(.opacity)
                    } else {
                        // The first read: the chart's room, nothing drawn yet.
                        Color.clear
                            .frame(height: WalkProgressChart.plotHeight + 64)
                            .accessibilityHidden(true)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: range)
                rangePicker
                footer
            }
            .padding(.vertical, 16)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let line = content.statusLine { YourWalksStatusLine(text: line) }
        }
    }

    /// 1W, 1M, 3M, 1Y, All; read as "1 week" and so on (DS8.5).
    private var rangePicker: some View {
        Picker(AppCopy.YourWalks.rangePicker.copy.text, selection: $range) {
            ForEach(WalkProgressRange.allCases) { range in
                Text(AppCopy.walkRangeShort(range).text)
                    .accessibilityLabel(AppCopy.walkRangeSpoken(range).text)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
        .disabled(progress == nil)
        .padding(.horizontal, 16)
    }

    /// The sheet's footer (DS5) and the recording line (DS8.2), as under
    /// the Calendar.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.YourWalks.footer.copy.text)
            if content.isRecording {
                Text(AppCopy.YourWalks.todayPending.copy.text)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.textMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

/// The chart (DS6): "312 blocks" in `.title2` over the range's gain (or
/// "Since Mar 2024" for All), then a step line of cumulative walked blocks
/// in the `walked` cyan, no fill. The y-axis runs from the range's minimum
/// to its maximum (from zero for All); a single day draws a point.
///
/// Scrubbing swaps the header to the day under the finger, its count over
/// its date, at a fixed height (both versions are laid out, one hidden);
/// lifting clears the selection. No haptic. VoiceOver reads the header and
/// chart as one adjustable element that steps a day at a time, with an
/// Audio Graph (spec AC 13).
struct WalkProgressChart: View {
    let slice: WalkProgressSlice
    let headline: Int
    /// The day index under the finger; `nil` once it lifts.
    @State private var rawSelection: Int?
    /// The day VoiceOver has stepped to; `nil` reads the range summary.
    @State private var voiceOverIndex: Int?

    static let plotHeight: CGFloat = 240

    var body: some View {
        let selected = slice.selection(at: rawSelection)
        VStack(alignment: .leading, spacing: 12) {
            header(selected)
                .padding(.horizontal, 16)
            chart(selected)
                .frame(height: Self.plotHeight)
                .padding(.horizontal, 16)
                // Axis labels stay at the default size: a month's five
                // dates overlapped at accessibility sizes, and today's and
                // the one before it still at xxxLarge (simulator captures).
                // The header, which carries the numbers that matter, scales
                // fully, and VoiceOver reads every day.
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppCopy.YourWalks.chartLabel.copy.text)
        .accessibilityValue(voiceOverValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: voiceOverIndex = slice.stepped(from: voiceOverIndex, by: 1)
            case .decrement: voiceOverIndex = slice.stepped(from: voiceOverIndex, by: -1)
            @unknown default: break
            }
        }
        .accessibilityChartDescriptor(WalkProgressAudioGraph(slice: slice))
        .accessibilityIdentifier("yourWalks.progress.chart")
    }

    private var voiceOverValue: String {
        guard let voiceOverIndex else {
            return AppCopy.walkProgressRestValue(headline: headline, slice: slice).text
        }
        let point = slice.point(at: voiceOverIndex)
        return AppCopy.walkProgressValue(count: point.count, day: point.day).text
    }

    /// Both versions laid out in one place, the inactive one hidden, so the
    /// header keeps its height while scrubbing.
    private func header(_ selected: WalkProgressSlice.Point?) -> some View {
        let atRest = selected == nil
        return VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .leading) {
                Text(AppCopy.walkDayBlocks(headline).text).opacity(atRest ? 1 : 0)
                Text(AppCopy.walkDayBlocks(selected?.count ?? headline).text).opacity(atRest ? 0 : 1)
            }
            .font(.title2)
            .foregroundStyle(.primary)
            ZStack(alignment: .leading) {
                Text(AppCopy.walkProgressSummary(slice).text).opacity(atRest ? 1 : 0)
                Text(selected.map { AppCopy.walkDayTitle($0.day).text } ?? AppCopy.walkProgressSummary(slice).text)
                    .opacity(atRest ? 0 : 1)
            }
            .font(.subheadline)
            .foregroundStyle(Color.textMuted)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ selected: WalkProgressSlice.Point?) -> some View {
        let ticks = Dictionary(slice.xTicks.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        return Chart {
            ForEach(slice.linePoints) { point in
                LineMark(x: .value("Day", point.index), y: .value("Blocks", point.count))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.walked)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if slice.isSingleDay {
                PointMark(x: .value("Day", 0), y: .value("Blocks", slice.counts[0]))
                    .foregroundStyle(Color.walked)
                    .symbolSize(64)
            }
            if let selected {
                RuleMark(x: .value("Day", selected.index))
                    .foregroundStyle(Color.textMuted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Day", selected.index), y: .value("Blocks", selected.count))
                    .foregroundStyle(Color.walked)
                    .symbolSize(48)
            }
        }
        .chartXScale(domain: slice.isSingleDay ? -1 ... 1 : 0 ... slice.lastIndex)
        .chartYScale(domain: slice.yDomain)
        .chartXAxis {
            AxisMarks(values: slice.xTicks.map(\.index)) { value in
                AxisGridLine()
                AxisValueLabel(anchor: Self.labelAnchor(value.as(Int.self), lastIndex: slice.lastIndex)) {
                    if let index = value.as(Int.self), let tick = ticks[index] {
                        Text(AppCopy.walkChartAxisLabel(tick.day, style: tick.style).text)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: slice.yTicks) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $rawSelection)
    }

    /// Swift Charts' default placement (just after the gridline), except
    /// today's label, which ends at the plot's trailing edge: placed after
    /// it, it ran out of the plot and was dropped (simulator capture).
    private static func labelAnchor(_ index: Int?, lastIndex: Int) -> UnitPoint? {
        lastIndex > 0 && index == lastIndex ? .topTrailing : nil
    }
}

/// The chart's Audio Graph (spec AC 13): every day of the range, x as the
/// day, y in blocks.
private struct WalkProgressAudioGraph: AXChartDescriptorRepresentable {
    let slice: WalkProgressSlice

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(
            title: AppCopy.YourWalks.chartDayAxis.copy.text,
            range: 0 ... Double(max(1, slice.lastIndex)),
            gridlinePositions: slice.xTicks.map { Double($0.index) }
        ) { [slice] value in
            AppCopy.walkDayTitle(slice.day(at: min(max(Int(value.rounded()), 0), slice.lastIndex))).text
        }
        let domain = slice.yDomain
        let yAxis = AXNumericDataAxisDescriptor(
            title: AppCopy.YourWalks.chartBlocksAxis.copy.text,
            range: Double(domain.lowerBound) ... Double(domain.upperBound),
            gridlinePositions: slice.yTicks.map(Double.init)
        ) { AppCopy.walkDayBlocks(Int($0.rounded())).text }
        let series = AXDataSeriesDescriptor(
            name: AppCopy.YourWalks.chartSeries.copy.text,
            isContinuous: true,
            dataPoints: slice.counts.indices.map { AXDataPoint(x: Double($0), y: Double(slice.counts[$0])) }
        )
        return AXChartDescriptor(
            title: AppCopy.YourWalks.chartSeries.copy.text,
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
