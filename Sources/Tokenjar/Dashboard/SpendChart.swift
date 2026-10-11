import Charts
import SwiftUI
import TokenjarCore

struct SpendChart: View {
    var breakdown: SpendBreakdown
    var days: [Date]
    var colors: [Color]
    /// What the legend and tooltip call each of `breakdown.groups`, in the same order. Two groups may share one.
    var labels: [String]

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<Date?>(initialValue: nil)
    private var hover: Date? { hoverState.wrappedValue }

    private var xDomain: ClosedRange<Date> {
        let first = days.first ?? Date()
        let last = days.last ?? first
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    var body: some View {
        Chart {
            ForEach(breakdown.segments) { segment in
                BarMark(
                    x: .value("Day", segment.day, unit: .day),
                    y: .value("Cost", segment.cost),
                    width: .ratio(days.count > 7 ? 0.7 : 0.5)
                )
                .foregroundStyle(by: .value("Group", label(for: segment.group)))
                .opacity(hoveredDay == nil || hoveredDay == segment.day ? 1 : 0.45)
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
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Format.money(v)).monospacedDigit() }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: days.count > 7 ? .stride(by: .day, count: 5) : .stride(by: .day)) { _ in
                AxisValueLabel(format: days.count > 7 ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated).day(), centered: true)
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
        var rows: [(label: String, color: Color, cost: Double)] = []
        for segment in breakdown.segments where segment.day == day {
            let name = label(for: segment.group)
            if let index = rows.firstIndex(where: { $0.label == name }) {
                rows[index].cost += segment.cost
            } else {
                rows.append((name, color(for: segment.group), segment.cost))
            }
        }
        let total = rows.reduce(0) { $0 + $1.cost }
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(Format.money(total)).monospacedDigit().fontWeight(.semibold)
            }
            .font(.caption)
            ForEach(rows.reversed(), id: \.label) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 7, height: 7)
                    Text(row.label).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.money(row.cost)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(width: 220)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func color(for group: String) -> Color {
        guard let index = breakdown.groups.firstIndex(of: group), colors.indices.contains(index) else { return DashboardPalette.other }
        return colors[index]
    }
}
