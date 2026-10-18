import Foundation
import TokenjarCore

// `tokenjar --status` is the Mac app's `Tokenjar --status`: the stored numbers as JSON, with no check. `tokenjar --check`
// checks every account once, as the tray's Refresh now does, and prints what the tray's menu would show.

let usage = """
Usage: tokenjar --check | --status
  --check   check every account now and print what each one shows
  --status  print the last numbers of each account as JSON, without checking

"""

func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}

let arguments = CommandLine.arguments
let paths = AppPaths()

if arguments.dropFirst().first == "--check" {
    let store: SQLiteUsageStore
    do {
        try paths.createProbeDirectory()
        store = try SQLiteUsageStore(url: paths.databaseFile)
    } catch {
        write("Could not open Tokenjar's history in \(paths.supportDirectory.path).\n", to: .standardError)
        exit(1)
    }
    let engine = RefreshEngine(paths: paths, store: store)
    await engine.tick(force: true)
    if let problem = await engine.configProblem { write(problem + "\n", to: .standardError) }
    let summary = await engine.summary()
    write(summary.sections.isEmpty ? "No accounts found on this machine.\n" : summary.text + "\n", to: .standardOutput)
    exit(0)
}

if let status = StatusCommand.run(
    arguments, paths: paths, now: Date(), output: { write($0, to: .standardOutput) }, errorOutput: { write($0, to: .standardError) }
) {
    exit(status)
}

write(usage, to: .standardError)
exit(2)
