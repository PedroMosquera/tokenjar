import Foundation
import Testing
@testable import TokenjarCore

/// Plays `kimi web`: prints the banner lines at launch and keeps the stream open until terminated.
final class KimiServerConnection: CodexAppServerConnection, @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var terminateCount = 0

    init(banner: String) {
        (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        for line in banner.split(separator: "\n", omittingEmptySubsequences: false) { continuation.yield(Data(line.utf8)) }
    }

    func send(_ message: Data) throws {}

    func terminate() {
        lock.withLock { terminateCount += 1 }
        continuation.finish()
    }

    var terminated: Bool { lock.withLock { terminateCount > 0 } }
}

final class KimiLauncher: CodexAppServerLaunching, @unchecked Sendable {
    let connection: KimiServerConnection
    private let lock = NSLock()
    private var recorded: [(arguments: [String], environment: [String: String], directory: URL)] = []

    init(_ connection: KimiServerConnection) { self.connection = connection }

    func launch(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL) throws -> any CodexAppServerConnection {
        lock.withLock { recorded.append((arguments, environment, currentDirectory)) }
        return connection
    }

    var launches: [(arguments: [String], environment: [String: String], directory: URL)] { lock.withLock { recorded } }
}

final class KimiRouteTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [String: (Int, Data)]
    private var sent: [URLRequest] = []

    init(_ bodies: [String: (Int, Data)]) { self.bodies = bodies }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { sent.append(request) }
        let (status, body) = bodies[request.url?.path ?? ""] ?? (404, Data())
        return HTTPResponse(status: status, body: body)
    }
}

final class KimiUsageFetcherTests {
    let temp = TemporaryDirectory()
    var home: URL { temp.url }
    let account = AccountConfig(id: "kimi", provider: .kimi, label: "Kimi Code")
    let now = DateParsing.iso8601("2026-11-15T14:00:00Z")!

    init() throws {
        let bin = try temp.write("#!/bin/sh\nexit 1\n", to: "bin/kimi")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    }

    private func context(_ transport: KimiRouteTransport) -> FetchContext {
        FetchContext(
            http: HTTPClient(transport: transport),
            cli: CLILocator(home: home, overrides: [:], searchDirectories: [home.appending(path: "bin")]),
            paths: AppPaths(home: home), now: { [now] in now }
        )
    }

    private func recordedRoutes() throws -> KimiRouteTransport {
        KimiRouteTransport([
            KimiUsageFetcher.usagePath: (200, try fixture("Kimi/usage-plus.json")),
            KimiUsageFetcher.userInfoPath: (200, try fixture("Kimi/userinfo.json")),
        ])
    }

    // MARK: Banner

    @Test func bannerNamesThePortAndToken() async throws {
        let connection = KimiServerConnection(banner: try fixtureText("Kimi/banner.txt"))
        let banner = await KimiServerBanner.read(connection.lines)
        #expect(banner == KimiServerBanner(port: 50659, token: "placeholder-token"))
    }

    @Test func aServerThatExitsBeforeItsBannerGivesNothing() async {
        let connection = KimiServerConnection(banner: "  Kimi server ready  2.5.3\n  Local:    http://127.0.0.1:50659/")
        connection.terminate()
        #expect(await KimiServerBanner.read(connection.lines) == nil)
    }

    // MARK: Check

    @Test func startsTheServerOnAFreePortAndAsksOnlyItsTwoRoutes() async throws {
        let launcher = KimiLauncher(KimiServerConnection(banner: try fixtureText("Kimi/banner.txt")))
        let transport = try recordedRoutes()
        let context = context(transport)
        _ = try await KimiUsageFetcher(launcher: launcher).fetch(account, context: context)

        let launch = try #require(launcher.launches.first)
        #expect(launcher.launches.count == 1)
        #expect(launch.arguments == ["web", "--no-open", "--port", "0"])
        var expected = context.cli.baseEnvironment()
        expected["KIMI_DISABLE_TELEMETRY"] = "true"
        expected["KIMI_CODE_NO_AUTO_UPDATE"] = "true"
        #expect(launch.environment == expected)
        #expect(launch.directory == context.paths.probeDirectory)
        #expect(transport.requests.map { $0.url?.absoluteString } == [
            "http://127.0.0.1:50659/api/v1/oauth/usage", "http://127.0.0.1:50659/api/v1/oauth/userinfo",
        ])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer placeholder-token" })
        #expect(launcher.connection.terminated)
    }

    @Test func aProfileFolderBecomesKimiCodeHome() async throws {
        let launcher = KimiLauncher(KimiServerConnection(banner: try fixtureText("Kimi/banner.txt")))
        var account = self.account
        account.profileDir = "~/work-kimi"
        _ = try await KimiUsageFetcher(launcher: launcher).fetch(account, context: context(try recordedRoutes()))
        #expect(launcher.launches.first?.environment["KIMI_CODE_HOME"] == home.appending(path: "work-kimi").path)
    }

    @Test func recordedPlusAnswerShowsItsWindowsAndThePlan() async throws {
        let launcher = KimiLauncher(KimiServerConnection(banner: try fixtureText("Kimi/banner.txt")))
        let snapshot = try await KimiUsageFetcher(launcher: launcher).fetch(account, context: context(try recordedRoutes()))

        #expect(snapshot.plan == "Plus")
        #expect(snapshot.provider == .kimi)
        #expect(snapshot.source == "kimi web")
        #expect(snapshot.windows.map(\.id) == ["session", "monthly"])
        let session = try #require(snapshot.windows.first)
        #expect(abs(session.usedPercent - 9.88) < 0.0001)
        #expect(session.windowMinutes == 300)
        #expect(session.resetsAt == DateParsing.iso8601("2026-11-15T17:43:19Z"))
        let month = try #require(snapshot.windows.last)
        #expect(abs(month.usedPercent - 2.05) < 0.0001)
        #expect(month.resetsAt == DateParsing.iso8601("2026-12-10T00:00:00Z"))
        #expect(snapshot.notes == ["Kimi Code used 1.2% of the month"])
    }

    @Test func aFailedUserInfoReadKeepsTheLimits() async throws {
        let launcher = KimiLauncher(KimiServerConnection(banner: try fixtureText("Kimi/banner.txt")))
        let transport = KimiRouteTransport([KimiUsageFetcher.usagePath: (200, try fixture("Kimi/usage-plus.json"))])
        let snapshot = try await KimiUsageFetcher(launcher: launcher).fetch(account, context: context(transport))
        #expect(snapshot.plan == nil)
        #expect(snapshot.windows.count == 2)
    }

    @Test func aMissingCLIIsReportedWithoutLaunching() async throws {
        let launcher = KimiLauncher(KimiServerConnection(banner: ""))
        let context = FetchContext(
            http: HTTPClient(transport: try recordedRoutes()),
            cli: CLILocator(home: home, overrides: [:], searchDirectories: [home.appending(path: "nowhere")]), paths: AppPaths(home: home)
        )
        await #expect(throws: FetchError.cliNotFound("kimi")) {
            try await KimiUsageFetcher(launcher: launcher).fetch(self.account, context: context)
        }
        #expect(launcher.launches.isEmpty)
    }

    @Test func aServerThatNeverPrintsItsBannerTimesOutAndIsStopped() async throws {
        let launcher = KimiLauncher(KimiServerConnection(banner: "  Kimi server ready  2.5.3"))
        await #expect(throws: FetchError.timeout) {
            try await KimiUsageFetcher(launcher: launcher, timeout: 0.1).fetch(self.account, context: self.context(try self.recordedRoutes()))
        }
        #expect(launcher.connection.terminated)
    }

    // MARK: Answers

    private func body(_ data: String) -> Data {
        Data(#"{"code":0,"msg":"success","data":\#(data),"request_id":"placeholder"}"#.utf8)
    }

    @Test func weekAndBoosterAreShownWhenTheAnswerHasThem() throws {
        let data = #"{"kind":"ok","quota":{"usages":{"limit5h":{"usedRatio":0.5,"resetAt":"2026-11-15T17:00:00Z"},"limit7d":{"usedRatio":0.25,"resetAt":"2026-11-20T00:00:00Z"}},"extraUsage":{"balanceCents":1250,"totalCents":2000,"monthlyChargeLimitEnabled":false,"monthlyChargeLimitCents":0,"monthlyUsedCents":0,"currency":"USD"}}}"#
        let snapshot = try KimiUsageFetcher.snapshot(from: body(data), plan: nil, account: account, now: now)
        #expect(snapshot.windows.map(\.id) == ["session", "weekly"])
        #expect(snapshot.windows.last?.windowMinutes == 10_080)
        #expect(snapshot.notes == ["Booster: $12.50 left of $20.00"])
    }

    @Test(arguments: [
        (#"{"kind":"error","message":"Authorization failed. Please check your API key (try /login).","status":401}"#, FetchError.notSignedIn),
        (#"{"kind":"error","message":"Usage endpoint not available. Try Kimi For Coding.","status":404}"#, FetchError.noSubscription("No Kimi Code plan for this login")),
        (#"{"kind":"error","message":"Too many requests","status":429}"#, FetchError.rateLimited(retryAfter: nil)),
        (#"{"kind":"error","message":"Not logged in. Run kimi login."}"#, FetchError.notSignedIn),
        (#"{"kind":"error","message":"Failed to fetch usage: request timed out."}"#, FetchError.network("Kimi could not read the usage")),
    ])
    func errorsAreClassifiedWithoutShowingTheMessage(data: String, expected: FetchError) {
        #expect(throws: expected) { try KimiUsageFetcher.snapshot(from: self.body(data), plan: nil, account: self.account, now: self.now) }
    }

    @Test func anAnswerWithNoWindowIsAParseError() {
        let data = #"{"kind":"ok","quota":{"usages":{},"extraUsage":null}}"#
        #expect(throws: FetchError.parse("kimi usage has no 5-hour, weekly or monthly limit")) {
            try KimiUsageFetcher.snapshot(from: self.body(data), plan: nil, account: self.account, now: self.now)
        }
    }

    @Test func planNameIsTheOnlyUserInfoFieldRead() throws {
        #expect(KimiUsageFetcher.planName(try fixture("Kimi/userinfo.json")) == "Plus")
        #expect(KimiUsageFetcher.planName(body(#"{"kind":"ok","userInfo":{"userLevelName":""}}"#)) == nil)
    }

    // MARK: Loopback allowlist

    /// Pins the privacy promise in docs/privacy.md: plain HTTP only to this Mac, only these two routes.
    @Test func loopbackPathsArePinned() {
        #expect(HTTPClient.loopbackPaths == ["/api/v1/oauth/usage", "/api/v1/oauth/userinfo"])
    }

    @Test(arguments: ["http://127.0.0.1:50659/api/v1/oauth/usage", "http://127.0.0.1:1/api/v1/oauth/userinfo"])
    func theKimiRoutesOnLoopbackAreAllowed(url: String) {
        #expect(throws: Never.self) { try HTTPClient.validate(URL(string: url)!) }
    }

    @Test(arguments: [
        "http://127.0.0.1:50659/api/v1/sessions",
        "http://127.0.0.1:50659/api/v1/oauth/login",
        "http://127.0.0.1:50659/api/v1/shutdown",
        "http://127.0.0.1:50659/api/v1/oauth/usage?provider=x",
        "http://127.0.0.1/api/v1/oauth/usage",
    ])
    func otherLoopbackRequestsAreRefused(url: String) {
        let path = URL(string: url)!.path(percentEncoded: true)
        #expect(throws: HTTPClientError.endpointNotAllowed(path)) { try HTTPClient.validate(URL(string: url)!) }
    }

    @Test(arguments: [
        "http://localhost:50659/api/v1/oauth/usage",
        "http://192.168.1.10:50659/api/v1/oauth/usage",
        "http://api.kimi.ai/api/v1/oauth/usage",
    ])
    func plainHTTPToAnyOtherHostIsRefused(url: String) {
        #expect(throws: HTTPClientError.insecureScheme) { try HTTPClient.validate(URL(string: url)!) }
    }
}
