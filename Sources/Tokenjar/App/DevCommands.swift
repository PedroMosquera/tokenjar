import Foundation
import TokenjarCore

/// Developer entry points for checking fetchers and scanners against this Mac's real CLIs and logs.
/// Output is the snapshot JSON, aggregate counts or a redacted capture; none ever contains tokens, emails or prompt text.
///
///   Tokenjar --probe <provider> [--profile-dir DIR] [--credential-file FILE --credential-key KEY]
///   Tokenjar --capture <provider> [--profile-dir DIR] [--credential-file FILE --credential-key KEY]
///   Tokenjar --scan <provider> [--profile-dir DIR] [--days N]
enum DevCommands {
    /// What `--probe` and `--capture` touch. Tests point it at a temp home, fake CLIs and captured output.
    struct Environment {
        var paths = AppPaths()
        var cli = CLILocator()
        var process: any ProcessRunning = FoundationProcessRunner()
        var secrets: any SecretStore = KeychainSecretStore()
        var output: (String) -> Void = { print($0) }
        var errorOutput: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }

        var fetchContext: FetchContext {
            FetchContext(process: process, secrets: secrets, cli: cli, paths: paths)
        }
    }

    static func handle(_ args: [String]) async -> Bool {
        guard let status = await run(args, in: Environment()) else { return false }
        if status != 0 { exit(status) }
        return true
    }

    /// The exit status, or nil when `args` hold no dev command.
    static func run(_ args: [String], in environment: Environment) async -> Int32? {
        if let provider = value(after: "--capture", in: args) { return await capture(provider, args: args, in: environment) }
        if let provider = value(after: "--probe", in: args) { return await probe(provider, args: args, in: environment) }
        if let provider = value(after: "--scan", in: args) {
            scan(provider, args: args)
            return 0
        }
        return nil
    }

    private static func account(_ raw: String, args: [String], report: (String) -> Void) -> AccountConfig? {
        guard let provider = ProviderID(rawValue: raw) else {
            report("unknown provider \(raw); one of: \(ProviderID.allCases.map(\.rawValue).joined(separator: ", "))")
            return nil
        }
        var credential: CredentialRef?
        if let file = value(after: "--credential-file", in: args), let key = value(after: "--credential-key", in: args) {
            credential = .file(path: file, key: key)
        }
        return AccountConfig(id: "dev-\(raw)", provider: provider, label: "dev", profileDir: value(after: "--profile-dir", in: args), credential: credential)
    }

    private static func probe(_ raw: String, args: [String], in environment: Environment) async -> Int32 {
        guard let account = account(raw, args: args, report: environment.output) else { return 1 }
        if let refusal = latchRefusal(account.provider, in: environment) {
            environment.errorOutput(refusal)
            return 1
        }
        let started = Date()
        do {
            let snapshot = try await FetcherRegistry.fetcher(for: account.provider).fetch(account, context: environment.fetchContext)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            environment.output(String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "")
        } catch let error as FetchError {
            environment.output("FetchError: \(error) -> \(error.userMessage)")
        } catch {
            environment.output("error: \(type(of: error))")
        }
        environment.output(String(format: "took %.2fs", Date().timeIntervalSince(started)))
        return 0
    }

    /// Only the JSON document goes to stdout, so `> file.json` holds nothing else.
    private static func capture(_ raw: String, args: [String], in environment: Environment) async -> Int32 {
        guard let account = account(raw, args: args, report: environment.errorOutput) else { return 1 }
        if let refusal = latchRefusal(account.provider, in: environment) {
            environment.errorOutput(refusal)
            return 1
        }
        switch await Capture.run(account, context: environment.fetchContext) {
        case .document(let json):
            environment.output(json)
            return 0
        case .nothingToCapture(let message):
            environment.errorOutput(message)
            return 0
        case .stopped(let message):
            environment.errorOutput(message)
            return 1
        }
    }

    /// Hard rule 5: the app latched a probe that ran as a model turn, so running that CLI's binary again could spend
    /// tokens or quota. The latch file is only read; the app owns it.
    private static func latchRefusal(_ provider: ProviderID, in environment: Environment) -> String? {
        let cli: ProbeLatch.CLI
        switch provider {
        case .claude: cli = .claude
        case .antigravity: cli = .agy
        default: return nil
        }
        let file = environment.paths.supportDirectory.appending(path: ProbeLatch.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file), let latch = try? JSONDecoder().decode(ProbeLatch.self, from: data) else {
            return "Could not read \(ProbeLatch.fileName), so \(cli.rawValue) was not run: it may hold a latch on this \(cli.rawValue)."
        }
        guard latch.blocks(cli: cli, binary: ProbeLatch.fingerprint(ofBinaryAt: environment.cli.locate(cli.rawValue))) else { return nil }
        return "Tokenjar paused \(cli.rawValue) checks because its /usage probe ran as a model turn on this \(cli.rawValue) build, so running it again could spend \(cli == .claude ? "tokens" : "quota"). Nothing was run. If you accept that cost, click Try Once More on the account in Tokenjar, then run this again."
    }

    private static func scan(_ raw: String, args: [String]) {
        guard let account = account(raw, args: args, report: { print($0) }), let scanner = FetcherRegistry.scanner(for: account.provider) else {
            print("no scanner for \(raw)")
            return
        }
        let days = Int(value(after: "--days", in: args) ?? "30") ?? 30
        let started = Date()
        do {
            let result = try scanner.scan(account, checkpoints: [:], paths: AppPaths())
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            let store = InMemoryUsageStore()
            try store.upsert(result.events)
            let rows = try store.dailyUsage(accountIDs: nil, since: since)
            print("events: \(result.events.count) (unique \(Set(result.events.map(\.dedupeKey)).count)), checkpoints: \(result.checkpoints.count)")
            if let first = result.events.map(\.timestamp).min(), let last = result.events.map(\.timestamp).max() {
                print("range: \(first) .. \(last)")
            }
            var byModel: [String: (Int, Int, Int, Int, Double)] = [:]
            for row in rows {
                var v = byModel[row.model] ?? (0, 0, 0, 0, 0)
                v.0 += row.requests; v.1 += row.inputTokens; v.2 += row.outputTokens; v.3 += row.cacheReadTokens; v.4 += row.reportedCostUSD ?? 0
                byModel[row.model] = v
            }
            print("last \(days)d by model: requests, input, output, cacheRead, reportedCost")
            for (model, v) in byModel.sorted(by: { $0.value.0 > $1.value.0 }) {
                print("  \(model): \(v.0), \(v.1), \(v.2), \(v.3), \(String(format: "%.4f", v.4))")
            }
            print("projects: \(Set(rows.compactMap(\.project)).count), days with usage: \(Set(rows.map(\.day)).count)")
            let prices = PriceTable.load(bundled: ProviderLogo.resourceURL("pricing.json"), override: AppPaths().pricingOverrideFile)
            var costByModel: [String: Double] = [:]
            var unpriced = Set<String>()
            for row in rows {
                let priced = prices.priced(row)
                if let cost = priced.costUSD { costByModel[row.model, default: 0] += cost } else { unpriced.insert(row.model) }
            }
            print("API-equivalent cost, last \(days)d: \(String(format: "%.2f", costByModel.values.reduce(0, +))) USD")
            for (model, cost) in costByModel.sorted(by: { $0.value > $1.value }) { print("  \(model): \(String(format: "%.2f", cost))") }
            if !unpriced.isEmpty { print("no price for: \(unpriced.sorted().joined(separator: ", "))") }
        } catch {
            print("scan error: \(error)")
        }
        print(String(format: "took %.2fs", Date().timeIntervalSince(started)))
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
