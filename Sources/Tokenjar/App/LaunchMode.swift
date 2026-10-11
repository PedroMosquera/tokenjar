import Foundation

/// What the command line asks for. A developer flag that is not whole is refused rather than read as a normal launch,
/// which would move Headroom's folders and start probes.
enum LaunchMode: Equatable {
    case app
    case renderSnapshots(URL)
    case devCommand
    case invalid(String)

    static func parse(_ args: [String]) -> LaunchMode {
        if let flag = args.firstIndex(of: "--render-snapshots") {
            let directory = flag + 1 < args.count ? args[flag + 1] : ""
            guard !directory.isEmpty, !directory.hasPrefix("--") else { return .invalid("usage: Tokenjar --render-snapshots <dir>") }
            return .renderSnapshots(URL(fileURLWithPath: directory))
        }
        if args.contains("--probe") || args.contains("--scan") { return .devCommand }
        return .app
    }
}
