import SwiftUI

/// A Grid rather than Table, which is NSTableView-backed and may not draw in offscreen snapshot renders.
struct TopProjectsTable: View {
    var projects: [ProjectSummary]

    private var anyEstimate: Bool { projects.contains(where: \.isEstimate) }

    var body: some View {
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

            ForEach(projects) { project in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(project.project)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(project.project == DashboardMath.noProject ? .secondary : .primary)
                    Text(project.requests.formatted())
                    Text(Format.tokens(project.tokens))
                    Text(project.cost.map { Format.money($0) } ?? "no price")
                        .foregroundStyle(project.cost == nil ? .secondary : .primary)
                }
                .font(.callout)
                .monospacedDigit()
                .padding(.vertical, 6)
            }
        }
    }
}
