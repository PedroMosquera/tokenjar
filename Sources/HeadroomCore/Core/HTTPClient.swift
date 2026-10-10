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
    case insecureScheme
    case methodNotAllowed(String)
}

/// The only way the app talks to the network. GET only, HTTPS only, allowlisted hosts only, no redirects.
/// Adding a host here is a privacy decision: update docs/privacy.md and the test that pins this set.
public struct HTTPClient: Sendable {
    public static let allowedHosts: Set<String> = ["opencode.ai"]

    let transport: any HTTPTransport
    public var userAgent: String

    public init(transport: any HTTPTransport = URLSessionTransport(), userAgent: String = "Headroom") {
        self.transport = transport
        self.userAgent = userAgent
    }

    public static func validate(_ url: URL) throws {
        guard url.scheme == "https" else { throw HTTPClientError.insecureScheme }
        let host = url.host()?.lowercased() ?? ""
        guard allowedHosts.contains(host) else { throw HTTPClientError.hostNotAllowed(host) }
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
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

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
