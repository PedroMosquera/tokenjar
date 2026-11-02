import Charts
import SwiftUI
import TokenjarCore

/// The API value section of a plan card: one clickable line, and inside it tiles, 30 daily bars and the footer.
struct CostSectionView: View {
    @Environment(AppModel.self) private var model
    var accountID: String
    var content: CostSection.Content

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<Date?>(initialValue: nil)
    private var hoveredDay: CostSection.Day? { hoverState.wrappedValue.flatMap { content.day(at: $0) } }

    var body: some View {
        let isOpen = model.isCostSectionExpanded(accountID)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.setCostSectionExpanded(accountID, !isOpen) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text("API value")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    trailing
                        .monospacedDigit()
                }
                .font(.callout)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide the API value details" : "Show the API value details")
            .accessibilityLabel("API value")
            .accessibilityValue("\(content.today) today, \(content.trailing)")
            .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")

            if isOpen {
                tiles
                chart
                footer
            }
        }
    }

    private var trailing: Text {
        guard let multiple = content.multiple else { return Text("\(content.today) today · \(content.trailing)") }
        let style = content.highlightsTrailing ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)
        return Text("\(content.today) today · \(Text(multiple).foregroundStyle(style)) plan")
    }

    private var tiles: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: content.tiles.count, by: 2)), id: \.self) { index in
                GridRow {
                    ForEach(content.tiles[index..<min(index + 2, content.tiles.count)], id: \.title) { tile in
                        tileView(tile)
                    }
                }
            }
        }
    }

    private func tileView(_ tile: CostSection.Tile) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tile.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                let value = Text(tile.value).font(.callout.weight(.semibold)).foregroundStyle(tile.highlighted ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                if let detail = tile.detail {
                    Text("\(value) \(Text(detail).font(.caption).foregroundStyle(.secondary))")
                } else {
                    value
                }
            }
            .monospacedDigit()
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        let today = content.days.last?.date
        let hovered = hoveredDay
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily, 30 days")
                Spacer(minLength: 8)
                Text(hovered.map { content.readout($0) } ?? content.summary)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Chart {
                ForEach(content.days, id: \.date) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Amount", day.amount))
                        .foregroundStyle(Color.accentColor.opacity(day.date == today ? 1 : day.date == hovered?.date ? 0.7 : 0.4))
                        .cornerRadius(1.5)
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color(nsColor: .separatorColor))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                RuleMark(y: .value("Average", content.average))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                // Opposite sides, so the two labels never collide on a sparse month whose average sits just off zero.
                AxisMarks(position: .leading, values: [0]) { _ in
                    AxisValueLabel("0")
                }
                AxisMarks(position: .trailing, values: [content.average]) { _ in
                    AxisValueLabel("avg")
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...max(content.peak, content.average, 0.01))
            .chartPlotStyle { plot in
                plot.frame(height: 48)
            }
            .chartHoverDate(hoverState.projectedValue)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.spoken)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(content.footer, id: \.self) { line in
                Text(line)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open in Dashboard") {
                model.showDashboard(accountID: accountID)
                model.closePopover()
            }
            .buttonStyle(.link)
            .padding(.top, 2)
        }
        .font(.caption)
    }
}
