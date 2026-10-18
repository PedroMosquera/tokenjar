import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol ProcessRunning: Sendable {
    /// Runs to completion. stdin is closed after `stdin` is written (or immediately when nil).
    /// Output beyond `outputLimit` bytes per stream is discarded. On timeout the process is terminated.
    func run(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        // Output is read only on the readability handlers, each until its own EOF. A second read from this thread
        // after exit could land before a handler's last chunk and reorder stdout.
        let out = LimitedBuffer(limit: outputLimit), err = LimitedBuffer(limit: outputLimit)
        let drained = DispatchGroup(), exited = DispatchGroup()
        Self.collect(outPipe.fileHandleForReading, into: out, until: drained)
        Self.collect(errPipe.fileHandleForReading, into: err, until: drained)
        // Not waitUntilExit on a GCD thread: it has been seen to miss the exit and never return.
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        do {
            try launch(process)
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            // Balanced so the groups are never released while entered, which some libdispatch versions trap on.
            if out.finish() { drained.leave() }
            if err.finish() { drained.leave() }
            exited.leave()
            throw error
        }
        // A CLI that exits before reading stdin would otherwise raise SIGPIPE and kill the whole menu bar app.
        preventSIGPIPE(writingTo: inPipe.fileHandleForWriting)
        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exited.done()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return true
            }
            let first = await group.next() ?? false
            if first, process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            group.cancelAll()
            return first
        }
        await drained.done()

        return ProcessResult(exitCode: process.terminationStatus, stdout: out.data, stderr: err.data, timedOut: timedOut)
    }

    private static func collect(_ handle: FileHandle, into buffer: LimitedBuffer, until drained: DispatchGroup) {
        drained.enter()
        readUntilEOF(handle, onData: buffer.append) { if buffer.finish() { drained.leave() } }
    }
}

private extension DispatchGroup {
    func done() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in notify(queue: .global()) { c.resume() } }
    }
}

final class LimitedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var finished = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - storage.count
        if room > 0 { storage.append(chunk.prefix(room)) }
    }

    /// True only the first time, so an EOF delivered twice cannot leave a DispatchGroup twice.
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
