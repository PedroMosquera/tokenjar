import Foundation

/// Asks one provider's public status page about the products Tokenjar watches: one GET of `ProviderID.statusFeedURL`
/// with no headers of its own, so the request carries no key, cookie or account data.
public struct ProviderHealthFetcher: Sendable {
    public static let timeout: TimeInterval = 10

    let http: HTTPClient
    let now: @Sendable () -> Date

    public init(http: HTTPClient = HTTPClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.now = now
    }

    /// Throws `FetchError`: `.timeout`; `.network` when the host cannot be reached or answers anything but 200, a
    /// redirect included (HTTPClient never follows one); `.parse` when the body lacks what Tokenjar reads; `.unsupported`
    /// for a provider with no feed, without sending anything.
    public func fetch(_ provider: ProviderID) async throws -> ProviderHealthAnswer {
        guard let url = provider.statusFeedURL, let feed = ProviderHealthFeed.forProvider(provider) else {
            throw FetchError.unsupported("\(provider.displayName) has no status feed")
        }
        let response: HTTPResponse
        do {
            response = try await http.get(url, timeout: Self.timeout)
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch let error as URLError {
            throw FetchError.network("URLError \(error.code.rawValue)")
        } catch {
            throw FetchError.network(String(describing: type(of: error)))
        }
        let arrival = now()
        guard response.status == 200 else { throw FetchError.network("HTTP \(response.status)") }
        return ProviderHealthAnswer(items: try feed.items(from: response.body), answeredAt: Self.answeredAt(headers: response.headers, arrival: arrival))
    }

    /// When the page made this copy. Atlassian's CDN may serve a copy up to an hour old with a 200 when the origin fails
    /// (`stale-if-error=3600`), and `Age` says how old. `Date` counts only when `Age` is missing: it is read against this
    /// Mac's clock, so a clock running fast would otherwise age every answer.
    static func answeredAt(headers: [String: String], arrival: Date) -> Date {
        let age = headers["age"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            ?? headers["date"].flatMap(DateParsing.httpDate).map { arrival.timeIntervalSince($0) }
        return arrival.addingTimeInterval(-max(0, age ?? 0))
    }
}
