import Foundation
import TokenjarCore

/// Developer entry points for checking fetchers and scanners against this Mac's real CLIs and logs.
/// Output is the snapshot JSON or aggregate counts; neither ever contains tokens, emails or prompt text.
///
///   Tokenjar --probe <provider> [--profile-dir DIR] [--credential-file FILE --credential-key KEY]
///   Tokenjar --scan <provider> [--profile-dir DIR] [--days N]
enum DevCommands {
    static func handle(_ args: [String]) async -> Bool {
        if let provider = value(after: "--probe", in: args) {
            await probe(provider, args: args)
            return true
        }
        if let provider = value(after: "--scan", in: args) {
            scan(provider, args: args)
            return true
        }
        return false
    }

    private static func account(_ raw: String, args: [String]) -> AccountConfig? {
        guard let provider = ProviderID(rawValue: raw) else {
            print("unknown provider \(raw); one of: \(ProviderID.allCases.map(\.rawValue).joined(separator: ", "))")
            return nil
        }
        var credential: CredentialRef?
        if let file = value(after: "--credential-file", in: args), let key = value(after: "--credential-key", in: args) {
            credential = .file(path: file, key: key)
        }
        return AccountConfig(id: "dev-\(raw)", provider: provider, label: "dev", profileDir: value(after: "--profile-dir", in: args), credential: credential)
    }

    private static func probe(_ raw: String, args: [String]) async {
        guard let account = account(raw, args: args) else { return }
        let started = Date()
        do {
            let snapshot = try await FetcherRegistry.fetcher(for: account.provider).fetch(account, context: FetchContext())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(snapshot), encoding: .utf8) ?? "")
        } catch let error as FetchError {
            print("FetchError: \(error) -> \(error.userMessage)")
        } catch {
            print("error: \(type(of: error))")
        }
        print(String(format: "took %.2fs", Date().timeIntervalSince(started)))
    }

    private static func scan(_ raw: String, args: [String]) {
        guard let account = account(raw, args: args), let scanner = FetcherRegistry.scanner(for: account.provider) else {
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
