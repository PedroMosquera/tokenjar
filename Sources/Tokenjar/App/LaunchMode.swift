import Foundation

/// What the command line asks for. A developer flag that is not whole is refused rather than read as a normal launch,
/// which would move Headroom's folders and start probes.
enum LaunchMode: Equatable {
    case app
    case renderSnapshots(URL)
    case renderWindows(WindowRenderOptions)
    case devCommand
    case invalid(String)

    static func parse(_ args: [String]) -> LaunchMode {
        if let flag = args.firstIndex(of: "--render-snapshots") {
            let directory = flag + 1 < args.count ? args[flag + 1] : ""
            guard !directory.isEmpty, !directory.hasPrefix("--") else { return .invalid("usage: Tokenjar --render-snapshots <dir>") }
            return .renderSnapshots(URL(fileURLWithPath: directory))
        }
        let renderWindowsUsage = "usage: Tokenjar --render-windows <dir> [--real-data] [--only <name-prefix>]"
        if let flag = args.firstIndex(of: "--render-windows") {
            guard let directory = value(after: flag, in: args) else { return .invalid(renderWindowsUsage) }
            var only: [String] = []
            for index in args.indices where args[index] == "--only" {
                guard let prefix = value(after: index, in: args) else { return .invalid(renderWindowsUsage) }
                only.append(prefix)
            }
            return .renderWindows(WindowRenderOptions(directory: URL(fileURLWithPath: directory), realData: args.contains("--real-data"), only: only))
        }
        if args.contains("--real-data") || args.contains("--only") { return .invalid(renderWindowsUsage) }
        if let flag = args.firstIndex(of: "--capture") {
            guard value(after: flag, in: args) != nil else {
                return .invalid("usage: Tokenjar --capture <provider> [--profile-dir DIR] [--credential-file FILE --credential-key KEY]")
            }
            return .devCommand
        }
        if args.contains("--probe") || args.contains("--scan") { return .devCommand }
        return .app
    }

    private static func value(after index: Int, in args: [String]) -> String? {
        guard index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return value.isEmpty || value.hasPrefix("--") ? nil : value
    }
}

/// `Tokenjar --render-windows <dir> [--real-data] [--only <name-prefix>]`.
struct WindowRenderOptions: Equatable {
    var directory: URL
    /// The local config and a copy of its history instead of `AppModel.preview()`.
    var realData = false
    /// Screen name prefixes to render; empty renders every screen.
    var only: [String] = []
}
