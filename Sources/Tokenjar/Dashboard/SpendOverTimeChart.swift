import Charts
import SwiftUI
import TokenjarCore

/// Spend a seat billed per use actually added in each hour, day or week, from Tokenjar's own checks of its spend
/// limit. Periods before the first check stay empty rather than reading as nothing spent.
struct SpendOverTimeChart: View {
    var periods: [DashboardMath.SpendPeriod]
    var unit: Calendar.Component
    var currency: String
    /// Drawn as a dashed rule when the bars are days and the account has a daily budget.
    var dailyBudget: Double?

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<Date?>(initialValue: nil)
    private var hover: Date? { hoverState.wrappedValue }

    var body: some View {
        Chart {
            ForEach(periods, id: \.interval.start) { period in
                if let amount = period.amount {
                    BarMark(
                        x: .value("Period", period.interval.start, unit: unit),
                        y: .value("Spend", amount),
                        width: .ratio(periods.count > 10 ? 0.7 : 0.5)
                    )
                    .foregroundStyle(DashboardPalette.series(0))
                    .opacity(hovered == nil || hovered == period ? 1 : 0.45)
                }
            }
            if let dailyBudget {
                RuleMark(y: .value("Daily budget", dailyBudget))
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Daily budget \(money(dailyBudget))").font(.caption2).foregroundStyle(.orange)
                    }
            }
            if let hovered, let amount = hovered.amount {
                RuleMark(x: .value("Period", hovered.interval.start, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(hovered, amount: amount)
                    }
            }
        }
        .chartXScale(domain: (periods.first?.interval.start ?? Date())...(periods.last?.interval.end ?? Date()))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) { DashboardAxis.yLabel(money(v)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: unit == .hour ? 6 : 7)) { _ in
                AxisValueLabel(format: labelFormat)
            }
        }
        .chartHoverDate(hoverState.projectedValue)
    }

    private var hovered: DashboardMath.SpendPeriod? {
        guard let hover else { return nil }
        return periods.first { $0.interval.contains(hover) }
    }

    private var labelFormat: Date.FormatStyle {
        unit == .hour ? .dateTime.hour() : .dateTime.month(.abbreviated).day()
    }

    private func money(_ amount: Double) -> String {
        Format.money(amount, currency: currency, fractionDigits: amount < 100 && amount != amount.rounded() ? 2 : 0, locale: .autoupdatingCurrent)
    }

    private func tooltip(_ period: DashboardMath.SpendPeriod, amount: Double) -> some View {
        let title = switch unit {
        case .hour: period.interval.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .weekOfYear: "Week of " + period.interval.start.formatted(.dateTime.month(.abbreviated).day())
        default: period.interval.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(money(amount)).monospacedDigit().fontWeight(.semibold)
        }
        .font(.caption)
        .padding(8)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }
}
