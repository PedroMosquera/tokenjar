import Foundation

/// Asks the ECB for its daily euro reference rates: one GET with no headers of its own beyond `Accept`, so the request
/// carries no key, cookie or account data.
public struct ExchangeRateFetcher: Sendable {
    public static let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    public static let timeout: TimeInterval = 10

    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    /// Throws `FetchError`: `.timeout`; `.network` when the host cannot be reached or answers anything but 200, a
    /// redirect included (HTTPClient never follows one); `.parse` when the body has no dated Cube or no USD rate.
    public func fetch() async throws -> ExchangeRates {
        let response: HTTPResponse
        do {
            response = try await http.get(Self.url, headers: ["Accept": "application/xml"], timeout: Self.timeout)
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch let error as URLError {
            throw FetchError.network("URLError \(error.code.rawValue)")
        } catch {
            throw FetchError.network(String(describing: type(of: error)))
        }
        guard response.status == 200 else { throw FetchError.network("HTTP \(response.status)") }
        return try ExchangeRates.parse(response.body)
    }
}

/// When a fetch of the ECB rates is worth sending. The caller owns the other conditions (this Mac's currency is not
/// USD, the network is usable).
public enum ExchangeRateSchedule {
    public static let automaticCooldown: TimeInterval = 6 * 3600
    public static let userCooldown: TimeInterval = 120

    private static let publicationHour = 16

    /// The "yyyy-MM-dd" of the newest rate set the ECB should have published: 16:00 Europe/Berlin, Monday to Friday.
    /// Holidays are not modelled; the cooldown absorbs a day with no new rates.
    public static func latestPublicationDay(asOf now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var day = calendar.startOfDay(for: now)
        while true {
            let publishedAt = calendar.date(bySettingHour: publicationHour, minute: 0, second: 0, of: day)!
            let weekday = calendar.component(.weekday, from: day)
            if publishedAt <= now, weekday != 1, weekday != 7 { break }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func isDue(rates: ExchangeRates?, lastFruitlessAttempt: Date?, now: Date, userInitiated: Bool) -> Bool {
        if let attempt = lastFruitlessAttempt, now.timeIntervalSince(attempt) < (userInitiated ? userCooldown : automaticCooldown) {
            return false
        }
        guard let rates else { return true }
        return rates.date < latestPublicationDay(asOf: now)
    }
}
