import SwiftUI

/// A column per week and a row per weekday, darker for a costlier day, with a readout of the day under the pointer.
struct ActivityCalendarView: View, Equatable {
    /// With `activity`'s own load, all it draws from; content is only rebuilt for a new key.
    var contentKey: DashboardLoadKey?
    var activity: ActivityCalendar

    static func == (a: ActivityCalendarView, b: ActivityCalendarView) -> Bool {
        a.contentKey == b.contentKey
    }

    /// Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let hoverState = State<ActivityCalendar.Day?>(initialValue: nil)
    private var hover: ActivityCalendar.Day? { hoverState.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActivityGridLayout(weeks: activity.weeks.count) {
                GeometryReader { geometry in
                    grid
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let day = hoverDay(at: location, width: geometry.size.width)
                                if day != hover { hoverState.wrappedValue = day }
                            case .ended:
                                hoverState.wrappedValue = nil
                            }
                        }
                }
            }
            HStack(spacing: 8) {
                Text(hover.map { activity.readout($0) } ?? activity.summary())
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                legend
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // As wide as the grid at its largest, so the legend stays beside it in a wide window.
        .frame(maxWidth: ActivityGrid.labelWidth + CGFloat(activity.weeks.count) * ActivityGrid.maxPitch, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity, last 12 months")
        .accessibilityValue(activity.summary())
    }

    private var grid: some View {
        let calendar = Calendar.current
        let weeks = activity.weeks
        let months = activity.monthStarts(calendar: calendar)
        let hovered = hover?.date
        return Canvas { context, size in
            let layout = ActivityGrid(width: size.width, weeks: weeks.count)
            // Every other weekday is named, as GitHub does, so the labels never crowd the small rows.
            if let firstWeek = weeks.first {
                for row in [1, 3, 5] where firstWeek.indices.contains(row) {
                    let symbol = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: firstWeek[row].date) - 1]
                    let cell = layout.cell(week: 0, weekday: row)
                    context.draw(label(symbol), at: CGPoint(x: 0, y: cell.midY), anchor: .leading)
                }
            }
            var lastLabelX = -CGFloat.infinity
            for index in months {
                guard let date = weeks[index].last?.date else { continue }
                let text = context.resolve(label(date.formatted(.dateTime.month(.abbreviated))))
                // Held inside the canvas when the month starts in the last column, which would clip its name.
                let x = min(layout.cell(week: index, weekday: 0).minX, size.width - text.measure(in: size).width)
                // A month that starts in the first column or two would run into the next month's name.
                guard x - lastLabelX >= 28 else { continue }
                context.draw(text, at: CGPoint(x: x, y: 0), anchor: .topLeading)
                lastLabelX = x
            }
            for (index, week) in weeks.enumerated() {
                for (row, day) in week.enumerated() {
                    let rect = layout.cell(week: index, weekday: row)
                    let shape = Path(roundedRect: rect, cornerRadius: min(2, rect.width / 4))
                    let color = day.level > 0 ? DashboardPalette.activity[day.level - 1] : DashboardPalette.activityEmpty
                    context.fill(shape, with: .color(color))
                    if day.date == hovered {
                        context.stroke(shape, with: .color(.primary.opacity(0.7)), lineWidth: 1)
                    }
                }
            }
        }
    }

    private func hoverDay(at location: CGPoint, width: CGFloat) -> ActivityCalendar.Day? {
        guard let position = ActivityGrid(width: width, weeks: activity.weeks.count).position(at: location),
              activity.weeks[position.week].indices.contains(position.weekday) else { return nil }
        return activity.weeks[position.week][position.weekday]
    }

    private func label(_ text: String) -> Text {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0 ? DashboardPalette.activity[level - 1] : DashboardPalette.activityEmpty)
                    .frame(width: 10, height: 10)
            }
            Text("More")
        }
        .font(.caption2)
        .help(activity.metric == .cost
            ? "Each level is a quarter of the days with usage, by API-equivalent cost. A day with usage but no price is the lightest."
            : "Each level is a quarter of the days with usage, by tokens, since none of this usage has a price.")
    }
}

/// Gives the calendar the height its width calls for, so the cells stay square at any window width.
private struct ActivityGridLayout: Layout {
    var weeks: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(weeks) * 12 + ActivityGrid.labelWidth
        return CGSize(width: width, height: ActivityGrid(width: width, weeks: weeks).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
