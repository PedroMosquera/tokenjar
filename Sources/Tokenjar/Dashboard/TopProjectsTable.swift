import SwiftUI

/// A Grid rather than Table, which is NSTableView-backed and may not draw in offscreen snapshot renders.
struct TopProjectsTable: View {
    var projects: [ProjectSummary]

    private var anyEstimate: Bool { projects.contains(where: \.isEstimate) }

    var body: some View {
        let costs = Self.costColumn(projects.map(\.cost))
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Text("Project")
                Text("Requests").gridColumnAlignment(.trailing)
                Text("Tokens").gridColumnAlignment(.trailing)
                HStack(spacing: 4) {
                    Text("Cost")
                    if anyEstimate { EstimateBadge() }
                }
                .gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

            ForEach(Array(zip(projects, costs)), id: \.0.id) { project, cost in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(project.project)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(project.project == DashboardMath.noProject ? .secondary : .primary)
                    Text(project.requests.formatted())
                    Text(Format.tokens(project.tokens))
                    Text(cost ?? "no price")
                        .foregroundStyle(cost == nil ? .secondary : .primary)
                }
                .font(.callout)
                .monospacedDigit()
                .padding(.vertical, 6)
            }
        }
    }

    /// One precision for the whole column, the most any row needs, so the digits line up: "$351.00" over "$0.26".
    static func costColumn(_ costs: [Double?], currency: String = "USD", locale: Locale = .autoupdatingCurrent) -> [String?] {
        let needsCents = costs.contains { cost in cost.map { $0 < 100 && $0 != $0.rounded() } ?? false }
        return costs.map { $0.map { Format.money($0, currency: currency, fractionDigits: needsCents ? 2 : 0, locale: locale) } }
    }
}
