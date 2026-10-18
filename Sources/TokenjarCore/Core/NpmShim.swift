import Foundation

/// What an npm `.cmd` shim on Windows starts, read from the shim rather than run: running a .cmd goes through cmd.exe,
/// which parses the arguments again by its own rules and mangles quotes such as the JSON in `claude --settings`.
/// npm writes these with cmd-shim, whose last line ends `"%_prog%"  "%dp0%\node_modules\<package>\<entry>" %*`
/// (`%~dp0\` in older npm), `%dp0%` being the shim's own folder.
enum NpmShim: Equatable {
    /// A script for node, which npm puts beside the shim or leaves to the PATH.
    case node(script: URL)
    /// A program the shim starts directly.
    case program(URL)

    /// nil when `text` is not a cmd-shim this reads, or names something other than a script or a program.
    static func target(of text: String, in directory: URL) -> NpmShim? {
        for line in text.split(whereSeparator: \.isNewline).reversed() where line.contains("%*") {
            // Every other piece between quotes is quoted.
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 1 }.map(\.element)
            guard let entry = quoted.last(where: { $0.hasPrefix("%dp0%\\") || $0.hasPrefix("%~dp0\\") }) else { continue }
            let relative = entry.drop { $0 != "\\" }.dropFirst().replacingOccurrences(of: "\\", with: "/")
            let url = directory.appending(path: relative).standardizedFileURL
            switch url.pathExtension.lowercased() {
            case "exe": return .program(url)
            case "js", "cjs", "mjs", "": return .node(script: url)
            default: return nil
            }
        }
        return nil
    }
}
