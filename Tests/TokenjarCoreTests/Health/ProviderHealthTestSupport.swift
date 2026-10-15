import Foundation
@testable import TokenjarCore

enum HealthFixtures {
    static func data(_ name: String) throws -> Data {
        try fixture("ProviderHealth/\(name)")
    }

    /// A Statuspage fixture with some top-level component statuses replaced, keyed by component id, and its first
    /// incident changed by `incident`.
    static func statuspage(_ name: String, statuses: [String: String], incident: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var json = try object(name)
        json["components"] = (json["components"] as! [[String: Any]]).map { component in
            var component = component
            if let status = statuses[component["id"] as! String] { component["status"] = status }
            return component
        }
        var incidents = json["incidents"] as! [[String: Any]]
        if !incidents.isEmpty { incident(&incidents[0]) }
        json["incidents"] = incidents
        return try JSONSerialization.data(withJSONObject: json)
    }

    /// The saved OpenAI page data, nothing affected unless `affected` says so, after `edit` has changed its summary.
    static func openAI(affected: [(id: String, status: String)] = [], edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var json = try object("openai-proxy.json")
        var summary = json["summary"] as! [String: Any]
        summary["affected_components"] = affected.map { ["component_id": $0.id, "status": $0.status] }
        edit(&summary)
        json["summary"] = summary
        return try JSONSerialization.data(withJSONObject: json)
    }

    static func object(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
    }

    static func texts(_ provider: ProviderID, _ body: Data) throws -> [String] {
        try ProviderHealthFeed.forProvider(provider)!.items(from: body).map(\.text)
    }
}

/// Answers every request with one response or one error, and records what was sent.
final class HealthFakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<HTTPResponse, any Error>
    private var sent: [URLRequest] = []

    init(_ response: HTTPResponse) { result = .success(response) }
    init(error: any Error) { result = .failure(error) }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { sent.append(request) }
        return try result.get()
    }
}
