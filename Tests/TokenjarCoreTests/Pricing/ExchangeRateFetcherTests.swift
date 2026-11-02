import Foundation
import Testing
@testable import TokenjarCore

struct ExchangeRateFetcherTests {
    private func fetch(_ transport: HealthFakeTransport) async throws -> ExchangeRates {
        try await ExchangeRateFetcher(http: HTTPClient(transport: transport)).fetch()
    }

    /// The ECB gets Tokenjar's User-Agent and an XML Accept, and nothing else: no key, no cookie.
    @Test func sendsOneGETWithNoKeyOrCookie() async throws {
        let transport = HealthFakeTransport(HTTPResponse(status: 200, body: ExchangeRatesTests.ecb))
        let rates = try await fetch(transport)
        #expect(rates.date == "2026-10-30")
        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url == ExchangeRateFetcher.url)
        #expect(request.httpMethod == "GET")
        #expect(request.allHTTPHeaderFields == ["User-Agent": "Tokenjar", "Accept": "application/xml"])
        #expect(request.timeoutInterval == 10)
    }

    @Test func a404IsANetworkError() async {
        let transport = HealthFakeTransport(HTTPResponse(status: 404, body: Data()))
        await #expect(throws: FetchError.network("HTTP 404")) { try await fetch(transport) }
    }

    @Test func aTimeoutIsATimeout() async {
        let transport = HealthFakeTransport(error: URLError(.timedOut))
        await #expect(throws: FetchError.timeout) { try await fetch(transport) }
    }

    @Test func anotherURLErrorKeepsItsCode() async {
        let transport = HealthFakeTransport(error: URLError(.notConnectedToInternet))
        await #expect(throws: FetchError.network("URLError \(URLError.notConnectedToInternet.rawValue)")) { try await fetch(transport) }
    }

    @Test func aBodyWithoutRatesIsAParseError() async {
        let transport = HealthFakeTransport(HTTPResponse(status: 200, body: Data("<html/>".utf8)))
        await #expect(throws: FetchError.self) { try await fetch(transport) }
    }
}

struct ExchangeRateScheduleTests {
    private static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private static func berlinDate(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        berlin.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private static let monday1500 = berlinDate(2, 15)
    private static let monday1630 = berlinDate(2, 16, 30)
    private static let monday1700 = berlinDate(2, 17)
    private static let saturday1200 = berlinDate(31, 12, month: 10)

    private func rates(_ date: String) -> ExchangeRates { ExchangeRates(date: date, perEUR: ["USD": 1.1]) }

    @Test func publicationDayIsTheLastWeekdayAfterFourPMBerlin() {
        #expect(ExchangeRateSchedule.latestPublicationDay(asOf: Self.monday1500) == "2026-10-30")
        #expect(ExchangeRateSchedule.latestPublicationDay(asOf: Self.monday1630) == "2026-11-02")
        #expect(ExchangeRateSchedule.latestPublicationDay(asOf: Self.saturday1200) == "2026-10-30")
    }

    @Test func noRatesIsDue() {
        #expect(ExchangeRateSchedule.isDue(rates: nil, lastFruitlessAttempt: nil, now: Self.monday1700, userInitiated: false))
    }

    @Test func currentRatesAreNotDueAndStaleOnesAre() {
        #expect(!ExchangeRateSchedule.isDue(rates: rates("2026-11-02"), lastFruitlessAttempt: nil, now: Self.monday1700, userInitiated: false))
        #expect(ExchangeRateSchedule.isDue(rates: rates("2026-10-30"), lastFruitlessAttempt: nil, now: Self.monday1700, userInitiated: false))
    }

    @Test func ratesPublishedFridayAreCurrentOnMondayBeforeFourPM() {
        #expect(!ExchangeRateSchedule.isDue(rates: rates("2026-10-30"), lastFruitlessAttempt: nil, now: Self.monday1500, userInitiated: false))
    }

    @Test func aFruitlessAttemptHoldsAutomaticTriggersForSixHours() {
        let stale = rates("2026-10-30")
        let now = Self.monday1700
        #expect(!ExchangeRateSchedule.isDue(rates: stale, lastFruitlessAttempt: now.addingTimeInterval(-3600), now: now, userInitiated: false))
        #expect(ExchangeRateSchedule.isDue(rates: stale, lastFruitlessAttempt: now.addingTimeInterval(-(6 * 3600 + 60)), now: now, userInitiated: false))
    }

    @Test func aUserRefreshOnlyWaitsTwoMinutes() {
        let stale = rates("2026-10-30")
        let now = Self.monday1700
        #expect(ExchangeRateSchedule.isDue(rates: stale, lastFruitlessAttempt: now.addingTimeInterval(-3600), now: now, userInitiated: true))
        #expect(!ExchangeRateSchedule.isDue(rates: stale, lastFruitlessAttempt: now.addingTimeInterval(-60), now: now, userInitiated: true))
    }

    @Test func noRatesStillWaitsOutTheCooldown() {
        let now = Self.monday1700
        #expect(!ExchangeRateSchedule.isDue(rates: nil, lastFruitlessAttempt: now.addingTimeInterval(-60), now: now, userInitiated: false))
    }
}
