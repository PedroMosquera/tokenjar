import Foundation

enum KimiLocalData {
    /// KIMI_CODE_HOME, given as the account's profile folder, else ~/.kimi-code.
    static func home(for account: AccountConfig, paths: AppPaths) -> URL {
        account.profileDir.map(paths.expand) ?? paths.home.appending(path: ".kimi-code")
    }
}

/// Each `usage.record` line in `sessions/<workdir>/<session>/agents/<agent>/wire.jsonl` is one model request, not a
/// running total. A session's `state.json` also holds its title and last prompt, so only its `cwd` is decoded.
public struct KimiHistoryScanner: HistoryScanner {
    public let name = "kimi-wire"

    public init() {}

    public func scan(_ account: AccountConfig, checkpoints: ScanCheckpoints, paths: AppPaths) throws -> ScanResult {
        var events: [UsageEvent] = []
        var next: ScanCheckpoints = [:]
        for session in Self.sessionDirectories(in: KimiLocalData.home(for: account, paths: paths).appending(path: "sessions")) {
            let project = Self.project(of: session, home: paths.home)
            for url in Self.wireFiles(in: session) {
                let key = sha256Hex(url.path)
                autoreleasepool {
                    do {
                        let (fileEvents, checkpoint) = try Self.scanFile(
                            url, from: checkpoints[key].flatMap(Checkpoint.init), accountID: account.id, project: project
                        )
                        events += fileEvents
                        next[key] = checkpoint.encoded
                    } catch {
                        if let previous = checkpoints[key] { next[key] = previous }
                    }
                }
            }
        }
        return ScanResult(events: events, checkpoints: next)
    }

    public func sharedSourceKey(for account: AccountConfig, paths: AppPaths) -> String? {
        sha256Hex(KimiLocalData.home(for: account, paths: paths).standardizedFileURL.path)
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }

    static func sessionDirectories(in sessions: URL) -> [URL] {
        subdirectories(of: sessions).flatMap(subdirectories)
    }

    static func wireFiles(in session: URL) -> [URL] {
        subdirectories(of: session.appending(path: "agents"))
            .map { $0.appending(path: "wire.jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private struct SessionState: Decodable {
        var cwd: String?
    }

    static func project(of session: URL, home: URL) -> String? {
        guard let data = try? Data(contentsOf: session.appending(path: "state.json")),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else { return nil }
        return UsageEvent.project(fromWorkingDirectory: state.cwd, home: home)
    }

    /// The byte offset after the last complete line. A changed inode or a file shorter than `offset` starts over.
    struct Checkpoint: Codable, Equatable {
        var inode: UInt64
        var offset: Int
    }

    private struct Line: Decodable {
        var type: String
        var agentId: String?
        var model: String?
        var usage: Usage?
        var time: Double?
    }

    private struct Usage: Decodable {
        var inputOther: Int?
        var output: Int?
        var inputCacheRead: Int?
        var inputCacheCreation: Int?
    }

    private static let marker = Data(#""usage.record""#.utf8)

    /// `/fork` copies a session's wire lines, times included, into a new session, so the dedupe key is the record's
    /// content, never its file.
    static func scanFile(
        _ url: URL, from checkpoint: Checkpoint?, accountID: String, project: String?
    ) throws -> ([UsageEvent], Checkpoint) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0

        var start = 0
        if let checkpoint, checkpoint.inode == inode, checkpoint.offset <= size {
            if checkpoint.offset == size { return ([], checkpoint) }
            start = checkpoint.offset
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let tail = try handle.readToEnd() ?? Data()

        var events: [UsageEvent] = []
        var end = start
        for range in CodexRollouts.lineRanges(in: tail) {
            end = start + range.upperBound + 1
            let line = tail[range]
            guard CodexRollouts.contains(line, marker),
                  let decoded = try? JSONDecoder().decode(Line.self, from: line), decoded.type == "usage.record",
                  let usage = decoded.usage, let time = decoded.time, let alias = decoded.model, !alias.isEmpty else { continue }
            let input = max(0, usage.inputOther ?? 0), output = max(0, usage.output ?? 0)
            let cached = max(0, usage.inputCacheRead ?? 0), written = max(0, usage.inputCacheCreation ?? 0)
            guard input + output + cached + written > 0 else { continue }
            events.append(UsageEvent(
                dedupeKey: "kimi:\(decoded.agentId ?? ""):\(Int64(time)):\(alias):\(input):\(output):\(cached):\(written)", timestamp: Date(timeIntervalSince1970: time / 1000), accountID: accountID,
                harness: .kimiCode, model: model(fromAlias: alias), project: project,
                inputTokens: input, outputTokens: output, cacheReadTokens: cached, cacheWrite5mTokens: written
            ))
        }
        return (events, Checkpoint(inode: inode, offset: end))
    }

    /// Kimi logs the config alias, `<provider>/<model>`, and the part after the last slash is the model id.
    static func model(fromAlias alias: String) -> String {
        alias.split(separator: "/").last.map(String.init) ?? alias
    }
}

extension KimiHistoryScanner.Checkpoint {
    init?(_ encoded: String) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)), decoded.offset >= 0 else { return nil }
        self = decoded
    }

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
