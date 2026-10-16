import SwiftUI
import TokenjarCore

/// One window's cycles, newest first. A Grid like `TopProjectsTable`, for the same reason.
struct PercentWorthTable: View {
    var worth: PercentWorth
    var showsLabel: Bool

    var body: some View {
        let costs = TopProjectsTable.costColumn(worth.rows.map(\.costPerPercent))
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel {
                Text(worth.label).font(.subheadline.weight(.medium))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Text("Cycle")
                    Text("Peak").gridColumnAlignment(.trailing)
                    Text("Tokens per 1%").gridColumnAlignment(.trailing)
                    HStack(spacing: 4) {
                        Text("Cost per 1%")
                        if worth.rows.contains(where: \.isEstimate) { EstimateBadge() }
                    }
                    .gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 6)

                ForEach(Array(zip(worth.rows, costs)), id: \.0.id) { row, cost in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text(PercentWorth.cycleText(row))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.percent(row.cycle.peakPercent))
                        Text(Format.tokens(Int(row.tokensPerPercent.rounded())))
                        Text(cost ?? "no price")
                            .foregroundStyle(cost == nil ? .secondary : .primary)
                    }
                    .font(.callout)
                    .monospacedDigit()
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

extension PercentWorth {
    /// "Sep 21 to Sep 28", or "Sep 21 to now" for the cycle still running.
    static func cycleText(_ row: Row, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        return "\(row.cycle.start.formatted(style)) to \(row.isCurrent ? "now" : row.cycle.resetsAt.formatted(style))"
    }

    static let caption = "From this Mac's logs only. Use on other Macs, on the web or in other apps counts toward the provider's % "
        + "but not here, so these numbers can read high."

    static let help = "Tokens and API-equivalent cost from the start of each cycle to its highest check, divided by the % used at "
        + "that check. Usage is cut at the check's time, not at midnight. Cycles under \(Int(floorPercent))% used are left out, "
        + "and so is the cost when a model has no price. A drop from one cycle to the next can mean a tighter limit, or a "
        + "different mix of models."
}
