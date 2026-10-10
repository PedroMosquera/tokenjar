import Charts
import SwiftUI
import HeadroomCore

/// Used % per window (one account) or per account's tightest window (All), with the warn and critical
/// thresholds and a faint vertical rule at each reset.
struct LimitsChart: View {
    var content: DashboardContent
    var range: DashboardRange
    var warnAt: Int
    var criticalAt: Int

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<Date?>(initialValue: nil)
    private var hover: Date? { hoverState.wrappedValue }

    private var domain: ClosedRange<Date> {
        content.periods.now.addingTimeInterval(-range.duration)...content.periods.now
    }

    var body: some View {
        Chart {
            ForEach(content.resets) { marker in
                RuleMark(x: .value("Reset", marker.date))
                    .foregroundStyle(color(for: marker.seriesID).opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(content.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Used", point.usedPercent),
                    series: .value("Line", point.lineID)
                )
                .foregroundStyle(by: .value("Series", point.label))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            // After the lines so the threshold labels sit on top of them.
            threshold(warnAt, severity: .warning, name: "warn")
            threshold(criticalAt, severity: .critical, name: "critical")
            if let hover, domain.contains(hover) {
                RuleMark(x: .value("Hover", hover))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(at: hover)
                    }
            }
        }
        .chartForegroundStyleScale(domain: content.series.map(\.label), range: content.series.map { DashboardPalette.series($0.colorIndex) })
        .chartYScale(domain: 0...100)
        .chartXScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)%").monospacedDigit() }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 6)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartHoverDate(hoverState.projectedValue)
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.month(.abbreviated).day()
        }
    }

    @ChartContentBuilder
    private func threshold(_ percent: Int, severity: Severity, name: String) -> some ChartContent {
        RuleMark(y: .value(name, percent))
            .foregroundStyle(severity.color.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .annotation(position: .top, alignment: .trailing, spacing: 1) {
                Text("\(name) \(percent)%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.9), in: Capsule())
            }
    }

    private func color(for seriesID: String) -> Color {
        DashboardPalette.series(content.series.first { $0.id == seriesID }?.colorIndex ?? .max)
    }

    private func tooltip(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(range == .day ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour()))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(content.series) { series in
                if let point = Self.latest(content.pointsBySeries[series.id] ?? [], atOrBefore: date) {
                    HStack(spacing: 6) {
                        Circle().fill(DashboardPalette.series(series.colorIndex)).frame(width: 7, height: 7)
                        Text(series.label).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Format.percent(point.usedPercent)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(8)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private static func latest(_ points: [LimitPoint], atOrBefore date: Date) -> LimitPoint? {
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date <= date { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? points[low - 1] : nil
    }
}
