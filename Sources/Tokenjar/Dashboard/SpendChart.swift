import Charts
import SwiftUI
import TokenjarCore

struct SpendChart: View, Equatable {
    /// With `split` and `range`, all that `breakdown`, `periods`, `colors` and `labels` are built from.
    var contentKey: DashboardLoadKey?
    var split: DailySplit
    var range: DashboardRange
    var breakdown: SpendBreakdown
    var periods: DashboardPeriods
    var colors: [Color]
    /// What the legend and tooltip call each of `breakdown.groups`, in the same order. Two groups may share one.
    var labels: [String]
    /// Built from `breakdown`, so it needs no place in `==`.
    var reference: DailyReference?

    static func == (a: SpendChart, b: SpendChart) -> Bool {
        a.contentKey == b.contentKey && a.split == b.split && a.range == b.range
    }

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<Date?>(initialValue: nil)
    private var hover: Date? { hoverState.wrappedValue }

    private var days: [Date] { periods.days(of: range) }

    var body: some View {
        Chart {
            ForEach(breakdown.segments) { segment in
                BarMark(
                    x: .value("Day", segment.day, unit: .day),
                    y: .value(split == .tokenType ? "Tokens" : "Cost", segment.value),
                    width: .ratio(days.count > 7 ? 0.7 : 0.5)
                )
                .foregroundStyle(by: .value("Group", label(for: segment.group)))
                .opacity(hoveredDay == nil || hoveredDay == segment.day ? 1 : 0.45)
            }
            // After the bars, so a bar under a rule cannot hide it; before the tooltip, which covers both.
            if let reference {
                referenceRule(
                    reference.average, label: "Avg \(text(reference.average))", below: reference.averageLabelBelow,
                    accessibilityLabel: "Average per day, \(text(reference.average))"
                )
                referenceRule(
                    reference.peak, label: "Peak \(text(reference.peak))", below: false,
                    accessibilityLabel: "Peak day, \(reference.peakDay.formatted(.dateTime.weekday(.wide).month(.wide).day())), \(text(reference.peak))"
                )
            }
            if let day = hoveredDay {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(for: day)
                    }
            }
        }
        .chartForegroundStyleScale(domain: legend.map(\.label), range: legend.map(\.color))
        // The limits chart uses the same domain and labels, so a day sits at the same x in both cards.
        .chartXScale(domain: periods.chartDomain(of: range))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) { DashboardAxis.yLabel(text(v)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: DashboardAxis.labelDates(periods.axisDays(of: range))) { value in
                AxisValueLabel(format: DashboardAxis.dayFormat(range), anchor: DashboardAxis.labelAnchor(value, range: range))
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartHoverDate(hoverState.projectedValue)
    }

    private var hoveredDay: Date? {
        guard let hover else { return nil }
        let day = Calendar.current.startOfDay(for: hover)
        return days.contains(day) ? day : nil
    }

    /// One entry per label: a scale with a repeated domain value would draw the second group in the wrong color.
    private var legend: [(label: String, color: Color)] {
        var seen: Set<String> = []
        return breakdown.groups.compactMap { group in
            let name = label(for: group)
            return seen.insert(name).inserted ? (name, color(for: group)) : nil
        }
    }

    private func label(for group: String) -> String {
        guard let index = breakdown.groups.firstIndex(of: group), labels.indices.contains(index) else { return group }
        return labels[index]
    }

    private func tooltip(for day: Date) -> some View {
        var rows: [(label: String, color: Color, value: Double)] = []
        for segment in breakdown.segments where segment.day == day {
            let name = label(for: segment.group)
            if let index = rows.firstIndex(where: { $0.label == name }) {
                rows[index].value += segment.value
            } else {
                rows.append((name, color(for: segment.group), segment.value))
            }
        }
        let total = rows.reduce(0) { $0 + $1.value }
        // A token kind can be a sliver of its bar, so its share of the day says what the height cannot.
        let showsShare = split == .tokenType && total > 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(text(total)).monospacedDigit().fontWeight(.semibold)
            }
            .font(.caption)
            ForEach(rows.reversed(), id: \.label) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 7, height: 7)
                    Text(row.label).lineLimit(1)
                    Spacer(minLength: 8)
                    if showsShare {
                        Text(DashboardMath.share(row.value / total)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(text(row.value)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    /// Faint and labelled inside the plot at the leading edge, as the limits chart labels its thresholds. The label takes
    /// the card's background so the bar it sits on does not swallow it.
    private func referenceRule(_ value: Double, label: String, below: Bool, accessibilityLabel: String) -> some ChartContent {
        RuleMark(y: .value("Reference", value))
            .foregroundStyle(Color.secondary.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .accessibilityLabel(accessibilityLabel)
            .annotation(position: below ? .bottom : .top, alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .padding(.leading, 2)
            }
    }

    private func text(_ value: Double) -> String {
        split == .tokenType ? Format.tokens(Int(value.rounded())) : Format.money(value)
    }

    private func color(for group: String) -> Color {
        guard let index = breakdown.groups.firstIndex(of: group), colors.indices.contains(index) else { return DashboardPalette.other }
        return colors[index]
    }
}
