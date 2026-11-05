import Foundation

/// Report This Problem: a new GitHub issue on the update-failure form with what Tokenjar knows filled in. The person
/// reads it in the browser and submits it or not; opening the page already sends these fields to github.com.
public struct UpdateReport: Equatable, Sendable {
    public var from: String
    public var to: AppVersion
    public var method: UpdateMethod
    public var macOS: String
    public var swift: String
    /// The whole update log; only its last lines go in.
    public var log: String

    /// Below what browsers and GitHub reliably accept in an address.
    public static let maxURLLength = 8000
    public static let logLines = 40
    /// The ids in .github/ISSUE_TEMPLATE/update-failure.yml. GitHub fills a field only when its id is a query key.
    public static let fieldIDs = ["from", "to", "method", "macos", "swift", "log"]

    public init(from: String, to: AppVersion, method: UpdateMethod, macOS: String, swift: String, log: String) {
        self.from = from
        self.to = to
        self.method = method
        self.macOS = macOS
        self.swift = swift
        self.log = log
    }

    /// Every field is redacted with `home` and `user`. The oldest log lines are dropped until the address is shorter
    /// than `maxURLLength`, and a last line still too long is cut short rather than dropped, so the error stays.
    public func url(home: String, user: String) -> URL {
        // A short field's length is capped so the log always has room.
        let clean = { (text: String) in String(Self.redact(text, home: home, user: user).prefix(Self.shortFieldLimit)) }
        let fixed = [
            ("template", "update-failure.yml"), ("title", "Update to \(to) failed"), ("from", clean(from)),
            ("to", to.description), ("method", methodName), ("macos", clean(macOS)), ("swift", clean(swift)),
        ]
        var lines = Array(log.components(separatedBy: "\n").reversed().drop { $0.isEmpty }.reversed().suffix(Self.logLines))
            .map { Self.redact($0, home: home, user: user) }
        while true {
            let url = Self.address(fixed + [("log", lines.joined(separator: "\n"))])
            let over = url.absoluteString.count - (Self.maxURLLength - 1)
            if over <= 0 || lines.isEmpty { return url }
            // Each character takes at least one character of the address, so this shrinks it by at least `over`.
            if lines.count == 1, !lines[0].isEmpty { lines[0] = String(lines[0].dropLast(over)) } else { lines.removeFirst() }
        }
    }

    static let shortFieldLimit = 200

    /// The home folder becomes `~`, the per-user part of macOS's temporary folder (`/var/folders/<xx>/<id>`) becomes
    /// `<id>`, and the login name anywhere it is not inside a longer run of letters and digits becomes `<user>`, so
    /// `jdoe-mbp` and `com.jdoe.x` lose it too. A home of "/" or a one-letter name would rewrite nearly everything,
    /// so those are left alone.
    public static func redact(_ text: String, home: String, user: String) -> String {
        var text = text
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if !home.isEmpty { text = text.replacingOccurrences(of: home, with: "~") }
        text = text.replacingOccurrences(of: "/var/folders/[^/\\s]+/[^/\\s]+", with: "/var/folders/<id>", options: .regularExpression)
        guard user.count > 1 else { return text }
        let name = NSRegularExpression.escapedPattern(for: user)
        return text.replacingOccurrences(
            of: "(?<![A-Za-z0-9])\(name)(?![A-Za-z0-9])", with: "<user>", options: [.regularExpression, .caseInsensitive]
        )
    }

    private var methodName: String {
        switch method {
        case .homebrew: "Homebrew"
        case .releaseArchive: "Release archive"
        }
    }

    /// Encoded by hand: URLQueryItem leaves `+` alone, which GitHub reads as a space.
    private static func address(_ fields: [(String, String)]) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return URL(string: "https://github.com/PedroMosquera/tokenjar/issues/new?\(query)")!
    }
}
