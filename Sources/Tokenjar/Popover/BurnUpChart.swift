import Charts
import SwiftUI
import TokenjarCore

/// Used % over the current cycle of one window against the even-pace diagonal from 0 at the cycle
/// start to 100 at the reset. Points above the dashed line are ahead of pace. At the limit a band covers the time left
/// until the reset.
struct BurnUpChart: View {
    struct Point: Identifiable {
        var date: Date
        var used: Double
        var id: Date { date }
    }

    var window: UsageWindow
    var start: Date
    var points: [Point]
    var tint: Color
    /// The window's name, only where nothing nearby names it.
    var caption: String?
    var isDimmed = false

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<Date?>(initialValue: nil)
    private var hover: Date? { hoverState.wrappedValue }

    /// The window the verdict line judges when it lasts a day or more, so the chart never contradicts the line
    /// above it. Otherwise the weekly window, else the longest one; nil when no window has a known cycle.
    static func chartWindow(in windows: [UsageWindow], verdictWindowID: String? = nil) -> UsageWindow? {
        let candidates = windows.filter { !$0.notStarted && $0.resetsAt != nil && ($0.windowMinutes ?? 0) > 0 }
        if let verdictWindowID, let judged = candidates.first(where: { $0.id == verdictWindowID && ($0.windowMinutes ?? 0) >= 1_440 }) {
            return judged
        }
        return candidates.first { $0.id == "weekly" } ?? candidates.max { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }
    }

    static func cycleStart(of window: UsageWindow) -> Date? {
        guard let resetsAt = window.resetsAt, let minutes = window.windowMinutes, minutes > 0 else { return nil }
        return resetsAt.addingTimeInterval(-Double(minutes) * 60)
    }

    /// At least a tenth of the cycle and 1 % used: less draws a stub at the edge or a flat line on the floor, which
    /// says nothing the bar above does not.
    static func isWorthDrawing(_ points: [Point], start: Date, end: Date) -> Bool {
        guard let first = points.first, let last = points.last, end > start else { return false }
        let span = last.date.timeIntervalSince(first.date) / end.timeIntervalSince(start)
        return span >= 0.1 && (points.map(\.used).max() ?? 0) >= 1
    }

    /// This cycle's samples, ending at the live value, thinned to the peak of each 1/120 of the cycle: a 44 pt chart
    /// shows no more, and every mark costs layout on each draw.
    static func points(samples: [WindowSample], window: UsageWindow, start: Date, now: Date) -> [Point] {
        let end = window.resetsAt ?? now
        // A sample under a minute old is the live value, which is appended below.
        var kept = cycleSamples(samples, start: start, end: end).filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) >= 60 }
        kept.append(WindowSample(accountID: "", windowID: window.id, timestamp: now, usedPercent: window.usedPercent, resetsAt: window.resetsAt))
        return DashboardMath.downsample(kept, bucket: thinningBucket(start: start, end: end)).map { Point(date: $0.timestamp, used: $0.usedPercent) }
    }

    /// Matched by their own reset time too, because a sample taken just before the previous reset can carry a
    /// timestamp inside this cycle.
    static func cycleSamples(_ samples: [WindowSample], start: Date, end: Date) -> [WindowSample] {
        let halfCycle = end.timeIntervalSince(start) / 2
        return samples.filter { sample in
            sample.timestamp >= start && (sample.resetsAt.map { abs($0.timeIntervalSince(end)) < halfCycle } ?? true)
        }
    }

    /// From the live value to the reset, for a window at its limit. Nil below the limit.
    static func blockedSpan(window: UsageWindow, points: [Point]) -> ClosedRange<Date>? {
        guard window.usedPercent >= 100, let from = points.last?.date, let resetsAt = window.resetsAt, resetsAt > from else { return nil }
        return from...resetsAt
    }

    /// What fits under a popover-wide plot without labels touching.
    static let maxAxisLabels = 8

    /// The dashboard's axis, so a day reads the same in both, naming only whole days: a part-day at either end is too
    /// narrow for its name at popover width. A cycle with more days than fit names every nth day, with a grid line
    /// only at the start of each named one.
    static func timeAxis(start: Date, end: Date, calendar: Calendar = .current, locale: Locale = .current) -> LimitsTimeAxis {
        var axis = LimitsTimeAxis(start...end, calendar: calendar, locale: locale)
        axis.labels = axis.labels.filter { label in
            let day = calendar.startOfDay(for: label.date)
            return day >= start && (calendar.date(byAdding: .day, value: 1, to: day) ?? day) <= end
        }
        let stride = (axis.labels.count + maxAxisLabels - 1) / maxAxisLabels
        guard stride > 1 else { return axis }
        axis.labels = axis.labels.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        axis.grid = axis.labels.map { calendar.startOfDay(for: $0.date) }.filter { $0 > start }
        return axis
    }

    /// Nil before the first sample and after the live value, where nothing has been measured.
    static func used(at date: Date, in points: [Point]) -> Double? {
        guard let last = points.last, date <= last.date else { return nil }
        return points.last { $0.date <= date }?.used
    }

    static func thinningBucket(start: Date, end: Date) -> TimeInterval {
        end.timeIntervalSince(start) / 120
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            plot
                .opacity(isDimmed ? 0.5 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) usage this cycle")
        .accessibilityValue("\(Format.percent(window.usedPercent)) used")
    }

    private var plot: some View {
        let end = window.resetsAt ?? start
        let top = max(100, points.map(\.used).max() ?? 0)
        let blocked = Self.blockedSpan(window: window, points: points)
        let axis = Self.timeAxis(start: start, end: end)
        return Chart {
            RuleMark(y: .value("Used", 100))
                .foregroundStyle(Color(nsColor: .separatorColor))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
            if let blocked {
                RectangleMark(
                    xStart: .value("Time", blocked.lowerBound), xEnd: .value("Time", blocked.upperBound),
                    yStart: .value("Used", 0), yEnd: .value("Used", top)
                )
                .foregroundStyle(tint.opacity(0.1))
                .annotation(position: .overlay) {
                    // Under about a seventh of the cycle the band is narrower than the word.
                    if blocked.upperBound.timeIntervalSince(blocked.lowerBound) >= end.timeIntervalSince(start) / 7 {
                        Text("Blocked")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LineMark(x: .value("Time", start), y: .value("Used", 0), series: .value("Series", "pace"))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            LineMark(x: .value("Time", end), y: .value("Used", 100), series: .value("Series", "pace"))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Used", point.used))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.date), y: .value("Used", point.used), series: .value("Series", "used"))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("Time", last.date), y: .value("Used", last.used))
                    .foregroundStyle(tint)
                    .symbolSize(18)
            }
            if let hover, hover >= start, hover <= end {
                RuleMark(x: .value("Hover", hover))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(at: hover)
                    }
            }
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(1)))
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: axis.grid) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
            }
            AxisMarks(values: axis.labels.map(\.date)) { value in
                AxisValueLabel(anchor: .top) { Text(axis.labels[value.index].text) }
                    .font(.caption2)
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot
                .frame(height: 44)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
                }
        }
        .chartHoverDate(hoverState.projectedValue)
    }

    private func readout(at date: Date) -> some View {
        let time = Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        return Group {
            if let used = Self.used(at: date, in: points) {
                Text("\(time.foregroundStyle(.secondary)) \(Text(Format.percent(used)).monospacedDigit())")
            } else {
                time.foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
    }
}

/// The popover's copy of each chart's stored samples, already thinned, so re-running a card's body never queries
/// SQLite. An entry holds until the history changes or the window starts a new cycle. Not published: filling it
/// during a body must not trigger another one.
final class BurnUpSamples: ObservableObject {
    private struct Entry {
        var start: Date
        var revision: Int
        var samples: [WindowSample]
    }

    private var entries: [String: Entry] = [:]

    func samples(accountID: String, windowID: String, start: Date, end: Date, revision: Int, load: () -> [WindowSample]) -> [WindowSample] {
        let key = "\(accountID)\n\(windowID)"
        if let entry = entries[key], entry.start == start, entry.revision == revision { return entry.samples }
        let samples = DashboardMath.downsample(BurnUpChart.cycleSamples(load(), start: start, end: end), bucket: BurnUpChart.thinningBucket(start: start, end: end))
        entries[key] = Entry(start: start, revision: revision, samples: samples)
        return samples
    }
}
