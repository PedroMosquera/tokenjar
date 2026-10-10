import SwiftUI
import HeadroomCore

struct WindowRow: View {
    var window: UsageWindow
    var severity: Severity
    var pace: Pace?
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if window.notStarted {
                    Text("not started")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 0) {
                        Text(Format.percent(window.usedPercent))
                            .fontWeight(.semibold)
                        if let countdown = Format.countdown(to: window.resetsAt, now: now) {
                            Text(" · \(countdown)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
            UsageBar(
                fraction: window.notStarted ? 0 : window.usedPercent / 100,
                paceFraction: pace.map { $0.expectedPercent / 100 },
                tint: severity.color
            )
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(accessibilityValue)
    }

    private var helpText: String {
        guard !window.notStarted else { return "\(window.label) has not started; it begins with the next request." }
        var parts = ["\(Format.percent(window.usedPercent)) used"]
        if let pace { parts.append("even pace \(Format.percent(pace.expectedPercent))") }
        if let resetsAt = window.resetsAt { parts.append("resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))") }
        return parts.joined(separator: ", ")
    }

    private var accessibilityValue: String {
        guard !window.notStarted else { return "not started" }
        let countdown = Format.countdown(to: window.resetsAt, now: now).map { ", resets in \($0)" } ?? ""
        return "\(Format.percent(window.usedPercent)) used\(countdown)"
    }
}

/// Capsule meter with an optional even-pace tick. The tick cuts a notch through the bar so it stays
/// visible over both the fill and the track, in light and dark.
struct UsageBar: View {
    var fraction: Double
    var paceFraction: Double?
    var tint: Color

    private let barHeight: CGFloat = 6
    private let tickHeight: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if clamped > 0 {
                        Capsule().fill(tint).frame(width: max(barHeight, width * clamped))
                    }
                    if let x = tickOffset(width) {
                        Rectangle()
                            .frame(width: 4)
                            .offset(x: x - 1)
                            .blendMode(.destinationOut)
                    }
                }
                .frame(height: barHeight)
                .compositingGroup()
                if let x = tickOffset(width) {
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 2, height: tickHeight)
                        .offset(x: x)
                }
            }
            .frame(width: width, height: proxy.size.height)
        }
        .frame(height: tickHeight)
    }

    private func tickOffset(_ width: CGFloat) -> CGFloat? {
        guard let paceFraction else { return nil }
        return min(max(0, width * min(max(paceFraction, 0), 1) - 1), width - 2)
    }
}
