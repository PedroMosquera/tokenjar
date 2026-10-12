import Charts
import SwiftUI
import TokenjarCore

/// Used % per window (one account) or per account's tightest window (All), with the amber and red thresholds and a
/// faint vertical rule at each reset.
struct LimitsChart: View, Equatable {
    var content: DashboardContent
    var range: DashboardRange
    var warnAt: Int
    var criticalAt: Int

    /// Content is only ever rebuilt for a new key, so the key stands in for comparing every point.
    static func == (a: LimitsChart, b: LimitsChart) -> Bool {
        a.content.key == b.content.key && a.range == b.range && a.warnAt == b.warnAt && a.criticalAt == b.criticalAt
    }

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<Date?>(initialValue: nil)
    private var hover: Date? { hoverState.wrappedValue }

    /// The range the content was built for, which the page's picker may already have moved past while it reloads.
    private var shownRange: DashboardRange { content.key?.range ?? range }

    private var domain: ClosedRange<Date> { content.limitsDomain }

    /// Days at 7d and 30d, unless the history is new and the axis spans only a day or so.
    private var sharesSpendAxis: Bool { shownRange != .day && content.limitsSince == nil }

    var body: some View {
        let timeAxis = sharesSpendAxis ? nil : LimitsTimeAxis(domain)
        Chart {
            ForEach(content.resets) { marker in
                RuleMark(x: .value("Reset", marker.date))
                    .foregroundStyle(color(for: marker.seriesID).opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            // Before the data, so a line or dot near a threshold draws over its label instead of under it.
            threshold(warnAt, severity: .warning, below: criticalAt - warnAt < Self.closeThresholds)
            threshold(criticalAt, severity: .critical, below: false)
            ForEach(content.linePoints) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Used", point.usedPercent),
                    series: .value("Line", point.lineID)
                )
                .foregroundStyle(by: .value("Series", point.label))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            // A line between per-cycle peaks would draw a trend that never happened, and its last segment would
            // dive to the live value of a cycle that has only just started.
            ForEach(content.peakPoints) { point in
                PointMark(x: .value("Time", point.date), y: .value("Used", point.usedPercent))
                    .foregroundStyle(by: .value("Series", point.label))
                    .symbolSize(16)
            }
            if let hover, domain.contains(hover) {
                RuleMark(x: .value("Hover", hover))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(at: hover, spansHours: timeAxis?.spansHours ?? false)
                    }
            }
        }
        .chartForegroundStyleScale(domain: content.series.map(\.label), range: content.series.map { DashboardPalette.series($0.colorIndex) })
        // The padding lifts a series at 0% off the axis line, where it would otherwise disappear.
        .chartYScale(domain: 0...100, range: .plotDimension(startPadding: 4, endPadding: 2))
        // LimitsTimeAxis centres its labels; without room past "now" the plot clips one that sits near it.
        .chartXScale(domain: domain, range: .plotDimension(endPadding: sharesSpendAxis ? 0 : 12))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Int.self) { DashboardAxis.yLabel("\(v)%") }
                }
            }
        }
        .chartXAxis {
            if let timeAxis {
                AxisMarks(values: timeAxis.grid) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                }
                AxisMarks(values: timeAxis.labels.map(\.date)) { value in
                    AxisValueLabel(anchor: .top) { Text(timeAxis.labels[value.index].text) }
                }
            } else {
                let days = content.periods.axisDays(of: shownRange)
                AxisMarks(values: days) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                }
                AxisMarks(values: DashboardAxis.labelDates(days)) { value in
                    AxisValueLabel(format: DashboardAxis.dayFormat(shownRange), anchor: DashboardAxis.labelAnchor(value, range: shownRange))
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartHoverDate(hoverState.projectedValue)
    }

    /// Below this many points apart the two labels would overlap, so the amber one hangs under its rule.
    private static let closeThresholds = 8

    /// The rule is drawn in the color it stands for, so its label gives only the level.
    static func thresholdLabel(_ percent: Int, severity: Severity) -> String {
        "\(percent)%"
    }

    /// VoiceOver gets no color, so it hears what the rule means, in the words Settings uses for these levels.
    static func thresholdAccessibilityLabel(_ percent: Int, severity: Severity) -> String {
        "Turns \(severity == .critical ? "red" : "amber") at \(percent)%"
    }

    /// Labelled inside the plot at the leading edge, where the lines are oldest.
    private func threshold(_ percent: Int, severity: Severity, below: Bool) -> some ChartContent {
        RuleMark(y: .value("Threshold", percent))
            .foregroundStyle(severity.color.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .accessibilityLabel(Self.thresholdAccessibilityLabel(percent, severity: severity))
            .annotation(position: below ? .bottom : .top, alignment: .leading, spacing: 2) {
                Text(Self.thresholdLabel(percent, severity: severity))
                    .font(.caption2)
                    .foregroundStyle(severity.color)
                    .padding(.leading, 5)
            }
    }

    private func color(for seriesID: String) -> Color {
        DashboardPalette.series(content.series.first { $0.id == seriesID }?.colorIndex ?? .max)
    }

    private func tooltip(at date: Date, spansHours: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(spansHours ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour()))
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

/// The limits chart's x axis when it cannot share the spend chart's days: at 24h, and while the history is newer than
/// the range.
struct LimitsTimeAxis: Equatable {
    struct Label: Equatable {
        var date: Date
        var text: String
    }

    var grid: [Date]
    var labels: [Label]
    var spansHours: Bool

    /// Past a day and a half, a grid line at each midnight and each day at least half in view named once, in the
    /// middle of the part in view, so no label runs past the plot. Shorter spans get a grid line every 6 hours, named
    /// by the day at midnight and by the time otherwise, so an hour never reads as a date; those near either end go
    /// unnamed for the same reason.
    init(_ domain: ClosedRange<Date>, calendar: Calendar = .current, locale: Locale = .current) {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let dayStyle = style.weekday(.abbreviated).day()
        var days: [Date] = []
        var day = calendar.startOfDay(for: domain.lowerBound)
        while day <= domain.upperBound, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            days.append(day)
            day = next
        }
        spansHours = domain.upperBound.timeIntervalSince(domain.lowerBound) <= 36 * 3600

        guard spansHours else {
            grid = days.filter { $0 > domain.lowerBound }
            labels = days.compactMap { start in
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                let shown = max(start, domain.lowerBound)...min(end, domain.upperBound)
                let length = shown.upperBound.timeIntervalSince(shown.lowerBound)
                guard length >= 12 * 3600 else { return nil }
                return Label(date: shown.lowerBound.addingTimeInterval(length / 2), text: start.formatted(dayStyle))
            }
            return
        }
        grid = days
            .flatMap { day in [0, 6, 12, 18].compactMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: day) } }
            .filter(domain.contains)
        let margin: TimeInterval = 2 * 3600
        labels = grid
            .filter { $0.timeIntervalSince(domain.lowerBound) >= margin && domain.upperBound.timeIntervalSince($0) >= margin }
            .map { Label(date: $0, text: $0.formatted($0 == calendar.startOfDay(for: $0) ? dayStyle : style.hour().minute())) }
    }
}
