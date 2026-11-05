import Foundation
import TokenjarCore

/// Runs Update Now's steps as plain child processes. A child is not quit with this app, so the swap survives the
/// install script quitting Tokenjar.
struct ProcessUpdateRunner: UpdateRunning {
    func build(_ step: UpdateStep, log: URL) async -> Int32 {
        await withCheckedContinuation { continuation in
            do {
                try Self.launch(step, log: log) { continuation.resume(returning: $0) }
            } catch {
                Self.note("could not start \(step.executable): \(error.localizedDescription)", in: log)
                continuation.resume(returning: -1)
            }
        }
    }

    func install(_ step: UpdateStep, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws {
        try Self.launch(step, log: log, onExit: onExit)
    }

    /// The command line goes into the log, so a report shows which step failed. The environment does not: it holds
    /// the home folder path.
    private static func launch(_ step: UpdateStep, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws {
        note("$ " + ([step.executable] + step.arguments).joined(separator: " "), in: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        try output.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.arguments
        process.environment = step.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        // Below the menu bar app's own work, without confining a build of several minutes to the efficiency cores.
        process.qualityOfService = .utility
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
    }

    private static func note(_ line: String, in log: URL) {
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
