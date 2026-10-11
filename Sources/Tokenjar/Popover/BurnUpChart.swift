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

    /// This cycle's samples, ending at the live value. Matched by their own reset time too, because a sample
    /// taken just before the previous reset can carry a timestamp inside this cycle.
    static func points(samples: [WindowSample], window: UsageWindow, start: Date, now: Date) -> [Point] {
        let end = window.resetsAt ?? now
        let halfCycle = end.timeIntervalSince(start) / 2
        var points = samples
            .filter { sample in
                sample.timestamp >= start && sample.timestamp <= now
                    && (sample.resetsAt.map { abs($0.timeIntervalSince(end)) < halfCycle } ?? true)
            }
            .map { Point(date: $0.timestamp, used: $0.usedPercent) }
        if let last = points.last, now.timeIntervalSince(last.date) < 60 {
            points[points.count - 1].used = window.usedPercent
        } else {
            points.append(Point(date: now, used: window.usedPercent))
        }
        return points
    }

    var body: some View {
        let end = window.resetsAt ?? start
        let top = max(100, points.map(\.used).max() ?? 0)
        Chart {
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
        .overlay(alignment: .topLeading) {
            Text(window.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("\(window.label) usage this cycle")
        .accessibilityValue("\(Format.percent(window.usedPercent)) used")
    }
}
