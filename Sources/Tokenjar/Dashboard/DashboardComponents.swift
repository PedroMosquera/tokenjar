import Charts
import SwiftUI

struct DashboardCard<Accessory: View, Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface()
    }
}

extension DashboardCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

struct KPITile: View {
    var title: String
    var value: String
    var caption: String
    var isEstimate = false
    var valueStyle: Color?
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueStyle ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if isEstimate { EstimateBadge() }
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface()
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

extension PaceVerdict {
    /// `text` as the second clause of a sentence: "runs out ~15m before reset".
    var clause: String { text.prefix(1).lowercased() + text.dropFirst() }
}

/// Tiles in one row when each gets at least `minTileWidth`, else in two rows with the longer first (three over two,
/// four over three), so no row ends in an empty cell. Tiles in a row share its width. Picks from the proposed width alone: ViewThatFits measured both
/// arrangements, text scaling included, and added about 40 ms to every page switch.
struct TileRowsLayout: Layout {
    var spacing: CGFloat = 10
    var minTileWidth: CGFloat = 126

    func rows(width: CGFloat, count: Int) -> [Range<Int>] {
        let oneRow = CGFloat(count) * minTileWidth + CGFloat(count - 1) * spacing
        let top = (count + 1) / 2
        return width >= oneRow || count <= 3 ? [0..<count] : [0..<top, top..<count]
    }

    private func tileWidth(_ row: Range<Int>, in width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(row.count - 1)) / CGFloat(row.count)
    }

    private func height(_ row: Range<Int>, width: CGFloat, subviews: Subviews) -> CGFloat {
        let proposal = ProposedViewSize(width: tileWidth(row, in: width), height: nil)
        return row.map { subviews[$0].sizeThatFits(proposal).height }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? CGFloat(subviews.count) * (minTileWidth + spacing) - spacing
        let rows = rows(width: width, count: subviews.count)
        let heights = rows.map { height($0, width: width, subviews: subviews) }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(rows.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, count: subviews.count) {
            let width = tileWidth(row, in: bounds.width)
            let rowHeight = height(row, width: bounds.width, subviews: subviews)
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: rowHeight))
                x += width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

struct EstimateBadge: View {
    var body: some View {
        Text("est.")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .help("API-equivalent estimate from public prices")
    }
}

struct DashboardEmptyState: View {
    var systemImage: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func dashboardSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// What the limits and spend charts share so a date sits at the same x in both: the label dates and formats, and a
/// y-label column of one width, which sets where each plot starts.
enum DashboardAxis {
    static let yLabelWidth: CGFloat = 56

    static func yLabel(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: yLabelWidth, alignment: .trailing)
    }

    /// Noon of each day, so a label sits under its day's bar and inside its day on the line chart.
    static func labelDates(_ days: [Date]) -> [Date] {
        days.map { $0.addingTimeInterval(12 * 3600) }
    }

    /// Centered under its day, except today's at 30d, which ends at noon: half a 30d day is too narrow for a centered
    /// label, and the chart would truncate it at the plot's edge.
    static func labelAnchor(_ value: AxisValue, range: DashboardRange) -> UnitPoint {
        range == .month && value.index == value.count - 1 ? .topTrailing : .top
    }

    static func dayFormat(_ range: DashboardRange) -> Date.FormatStyle {
        range == .month ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated).day()
    }
}

extension View {
    /// Sets `date` to the x value under the pointer while it is over the plot, and to nil when it leaves.
    func chartHoverDate(_ date: Binding<Date?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            date.wrappedValue = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                        case .ended:
                            date.wrappedValue = nil
                        }
                    }
            }
        }
    }
}
