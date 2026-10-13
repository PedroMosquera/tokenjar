import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum HTTPClientError: Error, Equatable {
    case hostNotAllowed(String)
    case endpointNotAllowed(String)
    case insecureScheme
    case methodNotAllowed(String)
}

/// The only way the app talks to the network. GET only, HTTPS only, allowlisted endpoints only, no redirects.
/// Adding an endpoint here is a privacy decision: update docs/privacy.md and the tests that pin this set.
public struct HTTPClient: Sendable {
    /// Exact paths per host, so a caller cannot send the OpenCode key to another path or port on its host, and a status
    /// host serves only the one feed Tokenjar reads. Status checks send no key. Each host is the one that answers without
    /// a redirect, since none is ever followed.
    public static let allowedEndpoints: [String: Set<String>] = [
        "opencode.ai": ["/zen/go/v1/usage"],
        "status.claude.com": ["/api/v2/summary.json"],
        "status.openai.com": ["/proxy/status.openai.com"],
        "www.githubstatus.com": ["/api/v2/summary.json"],
    ]
    public static var allowedHosts: Set<String> { Set(allowedEndpoints.keys) }

    let transport: any HTTPTransport
    public var userAgent: String

    public init(transport: any HTTPTransport = URLSessionTransport.shared, userAgent: String = "Tokenjar") {
        self.transport = transport
        self.userAgent = userAgent
    }

    public static func validate(_ url: URL) throws {
        guard url.scheme == "https" else { throw HTTPClientError.insecureScheme }
        let host = url.host()?.lowercased() ?? ""
        guard let paths = allowedEndpoints[host] else { throw HTTPClientError.hostNotAllowed(host) }
        let path = url.path(percentEncoded: true)
        guard url.port == nil || url.port == 443, url.user() == nil, url.password() == nil, url.query() == nil, url.fragment() == nil,
              paths.contains(path) else { throw HTTPClientError.endpointNotAllowed(path) }
    }

    public func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 30) async throws -> HTTPResponse {
        try Self.validate(url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await transport.send(request)
    }
}

public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    /// The app's one transport. Its session is never invalidated and so keeps this delegate alive for good, which is
    /// fine once but leaks a session and its connection pool for every instance a caller creates and drops.
    public static let shared = URLSessionTransport()

    /// Ephemeral, with no cookie store, no cookies sent and no URL cache.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// The configuration of the session requests go through, so a test can pin it without sending one.
    var sessionConfiguration: URLSessionConfiguration { session.configuration }

    public override init() { super.init() }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.httpMethod == "GET" else { throw HTTPClientError.methodNotAllowed(request.httpMethod ?? "") }
        if let url = request.url { try HTTPClient.validate(url) }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }

    // Never follow redirects: a redirect could carry the Authorization header to another host.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
