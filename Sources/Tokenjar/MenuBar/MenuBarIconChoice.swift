import Foundation
import TokenjarCore

extension MenuBarIcon {
    enum Source: Equatable {
        case slot
        /// A file name in Resources/Marks.
        case mark(String)
        /// A file name in Resources/Logos.
        case logo(String)
        /// An SF Symbol name.
        case symbol(String)
    }

    var source: Source {
        guard let colon = rawValue.firstIndex(of: ":") else { return .slot }
        let name = String(rawValue[rawValue.index(after: colon)...])
        switch rawValue[..<colon] {
        case "mark": return .mark(name)
        case "logo": return .logo(name)
        default: return .symbol(name)
        }
    }

    var title: String {
        switch self {
        case .app: "Cooldown slot"
        case .markMana: "Mana"
        case .markTaper: "Taper"
        case .markTally: "Tally"
        case .markBurnrate: "Burnrate"
        case .markGenio: "Genio"
        case .logoClaude: "Claude"
        case .logoOpenAI: "ChatGPT / OpenAI"
        // antigravity.svg is the Gemini mark standing in for Antigravity, so it is named for what it shows.
        case .logoAntigravity: "Gemini"
        case .logoCopilot: "GitHub Copilot"
        case .logoOpenCode: "OpenCode"
        case .logoWindsurf: "Windsurf / Devin"
        case .symbolSparkles: "Sparkles"
        case .symbolBrain: "Brain"
        case .symbolCPU: "CPU"
        case .symbolGauge: "Gauge"
        }
    }

    /// How Settings names the choice at the start of a sentence: "The slot", "The Claude logo".
    var phrase: String {
        switch source {
        case .slot: "The slot"
        case .mark: "The \(title) mark"
        case .logo: "The \(title) logo"
        case .symbol: "The \(title) symbol"
        }
    }

    enum Group: CaseIterable {
        case app, marks, logos, symbols

        var title: String {
            switch self {
            case .app: "App mark"
            case .marks: "More marks"
            case .logos: "Provider logos"
            case .symbols: "Symbols"
            }
        }

        var icons: [MenuBarIcon] { MenuBarIcon.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch source {
        case .slot: .app
        case .mark: .marks
        case .logo: .logos
        case .symbol: .symbols
        }
    }
}
