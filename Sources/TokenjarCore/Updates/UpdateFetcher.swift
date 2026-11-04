import Foundation

/// A release number such as `v0.4.0`. Only plain dotted numbers parse, so a pre-release tag is never offered.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let parts: [Int]

    public init?(_ text: String) {
        let digits = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = digits.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = pieces.compactMap { piece in
            piece.allSatisfy(\.isASCII) && piece.allSatisfy(\.isNumber) ? Int(piece) : nil
        }
        guard !pieces.isEmpty, numbers.count == pieces.count else { return nil }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    private func padded(to count: Int) -> [Int] { parts + Array(repeating: 0, count: max(0, count - parts.count)) }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }

    /// Hashes the parts without trailing zeros so it agrees with `==`.
    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    public var pageURL: URL

    public init(version: AppVersion, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }
}

/// Asks GitHub for Tokenjar's latest release: one GET with no key or identifier. The page URL is built from the tag,
/// never read from the response, so the answer cannot point the About link at another site.
public struct UpdateFetcher: Sendable {
    public static let url = URL(string: "https://api.github.com/repos/PedroMosquera/tokenjar/releases/latest")!
    public static let timeout: TimeInterval = 10

    private static let releasePage = "https://github.com/PedroMosquera/tokenjar/releases/tag/"

    public static func releaseInfo(for version: AppVersion) -> ReleaseInfo? {
        URL(string: releasePage + "v\(version)").map { ReleaseInfo(version: version, pageURL: $0) }
    }

    private struct Latest: Decodable {
        let tag_name: String
    }

    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    /// Throws `FetchError`: `.timeout`; `.network` when the host cannot be reached or answers anything but 200, a
    /// redirect included (HTTPClient never follows one); `.parse` when the body has no tag or the tag is not a plain version.
    public func fetch() async throws -> ReleaseInfo {
        let response: HTTPResponse
        do {
            response = try await http.get(Self.url, headers: ["Accept": "application/vnd.github+json"], timeout: Self.timeout)
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch let error as URLError {
            throw FetchError.network("URLError \(error.code.rawValue)")
        } catch {
            throw FetchError.network(String(describing: type(of: error)))
        }
        guard response.status == 200 else { throw FetchError.network("HTTP \(response.status)") }
        guard let latest = try? JSONDecoder().decode(Latest.self, from: response.body) else {
            throw FetchError.parse("no tag_name in the release")
        }
        guard let version = AppVersion(latest.tag_name), let release = Self.releaseInfo(for: version) else {
            throw FetchError.parse("unrecognised release tag")
        }
        return release
    }
}
