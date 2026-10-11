import Charts
import SwiftUI
import TokenjarCore

/// Used % over the current cycle of one window against the even-pace diagonal from 0 at the cycle
/// start to 100 at the reset. Points above the dashed line are ahead of pace.
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
        return Chart {
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
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(1)))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
            }
        }
        .frame(height: 44)
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
