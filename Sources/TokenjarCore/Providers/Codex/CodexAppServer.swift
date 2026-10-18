import Foundation

/// A running `codex app-server`: newline-delimited JSON objects over stdio. Not JSON-RPC 2.0 (no "jsonrpc" field).
protocol CodexAppServerConnection: Sendable {
    /// Lines from stdout without the trailing newline. Finishes when the process closes stdout or `terminate()` runs.
    var lines: AsyncStream<Data> { get }
    func send(_ message: Data) throws
    /// Idempotent. Closes stdin, stops the process and finishes `lines`.
    func terminate()
}

protocol CodexAppServerLaunching: Sendable {
    func launch(
        executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL
    ) throws -> any CodexAppServerConnection
}

enum CodexAppServerError: Error, Equatable {
    /// The server answered a request with an error object. The message is used only to classify the failure.
    case rpc(method: String, message: String)
    case exited
    case timeout
    case malformed
}

/// The whole conversation Tokenjar has with codex: a handshake and one read-only rate limit request.
/// Never add `account/read` with `refreshToken: true`, or any consume, nudge or task method.
enum CodexAppServerSession {
    static let rateLimitsMethod = "account/rateLimits/read"

    /// Returns the raw `account/rateLimits/read` response line. Notifications and server-initiated requests are ignored.
    /// Only `--capture codex` passes false, to see the reset-credit inventory's shape; the fetcher never decodes it.
    static func readRateLimits(
        over connection: any CodexAppServerConnection, clientVersion: String, excludeResetCreditDetails: Bool = true
    ) async throws -> Data {
        var lines = connection.lines.makeAsyncIterator()
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tokenjar", "version": clientVersion]]], over: connection)
        _ = try await response(to: 1, method: "initialize", from: &lines)
        try send(["method": "initialized"], over: connection)
        try send(["id": 2, "method": rateLimitsMethod, "params": ["excludeResetCreditDetails": excludeResetCreditDetails]], over: connection)
        return try await response(to: 2, method: rateLimitsMethod, from: &lines)
    }

    private static func send(_ message: [String: Any], over connection: any CodexAppServerConnection) throws {
        try connection.send(JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]))
    }

    private static func response(to id: Int, method: String, from lines: inout AsyncStream<Data>.Iterator) async throws -> Data {
        while let line = await lines.next() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["method"] == nil, (object["id"] as? Int) == id
            else { continue }
            if let error = object["error"] as? [String: Any] {
                throw CodexAppServerError.rpc(method: method, message: error["message"] as? String ?? "")
            }
            guard object["result"] != nil else { throw CodexAppServerError.malformed }
            return line
        }
        throw CodexAppServerError.exited
    }
}

struct ProcessCodexAppServerLauncher: CodexAppServerLaunching {
    func launch(
        executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL
    ) throws -> any CodexAppServerConnection {
        try ProcessCodexAppServerConnection(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
    }
}

final class ProcessCodexAppServerConnection: CodexAppServerConnection, @unchecked Sendable {
    /// A line longer than this is dropped; real responses are a few kilobytes.
    static let maxLineBytes = 4 << 20

    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    #if os(Windows)
    private let child: WindowsChildProcess
    #else
    private let process = Process()
    #endif
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var terminated = false

    init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL) throws {
        #if os(Windows)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        do {
            child = try WindowsChildProcess(
                executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory,
                captureErrors: false
            )
        } catch {
            continuation.finish()
            throw error
        }
        (lines, self.continuation) = (stream, continuation)
        input = child.input
        output = child.output
        readUntilEOF(output, onData: { [weak self] in self?.receive($0) }, atEOF: { [weak self] in self?.finish() })
        #else
        (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        let inPipe = Pipe(), outPipe = Pipe()
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        // Without this, writing after the server exits raises SIGPIPE and kills the whole app.
        preventSIGPIPE(writingTo: input)

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        readUntilEOF(output, onData: { [weak self] in self?.receive($0) }, atEOF: { [weak self] in self?.finish() })
        do {
            try launch(process)
        } catch {
            output.readabilityHandler = nil
            continuation.finish()
            throw error
        }
        #endif
    }

    func send(_ message: Data) throws {
        try input.write(contentsOf: message + Data("\n".utf8))
    }

    func terminate() {
        let alreadyTerminated = lock.withLock {
            defer { terminated = true }
            return terminated
        }
        guard !alreadyTerminated else { return }
        output.readabilityHandler = nil
        try? input.close()
        #if os(Windows)
        child.terminate()
        #else
        if process.isRunning {
            process.terminate()
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        #endif
        continuation.finish()
    }

    private func receive(_ chunk: Data) {
        let complete: [Data] = lock.withLock {
            buffer.append(chunk)
            var out: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                out.append(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.maxLineBytes { buffer.removeAll() }
            return out
        }
        for line in complete { continuation.yield(line) }
    }

    private func finish() {
        let rest = lock.withLock {
            defer { buffer.removeAll() }
            return buffer
        }
        if !rest.isEmpty { continuation.yield(rest) }
        continuation.finish()
    }
}
