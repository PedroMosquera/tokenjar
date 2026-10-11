import Foundation
import Testing
@testable import TokenjarCore

struct CodexAppServerSessionTests {
    @Test func handshakeThenOneReadOnlyRequest() async throws {
        let rateLimits = try CodexFixtures.line("rate-limits-plus.json")
        let connection = ScriptedCodexConnection.answering(rateLimits: rateLimits)

        let line = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "1.2.3")

        #expect(String(decoding: line, as: UTF8.self) == rateLimits)
        #expect(connection.sentMethods == ["initialize", "initialized", "account/rateLimits/read"])
        let sent = connection.sentObjects
        #expect(sent.map { $0["id"] as? Int } == [1, nil, 2])
        let clientInfo = (sent[0]["params"] as? [String: Any])?["clientInfo"] as? [String: String]
        #expect(clientInfo == ["name": "headroom", "version": "1.2.3"])
        #expect((sent[2]["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool == true)
        for raw in connection.sent.map({ String(decoding: $0, as: UTF8.self) }) {
            #expect(!raw.contains("jsonrpc"))
            #expect(!raw.contains("refreshToken"))
            #expect(!raw.contains("\n"))
        }
    }

    @Test func skipsNotificationsServerRequestsAndOtherIds() async throws {
        let rateLimits = try CodexFixtures.line("rate-limits-plus.json")
        let connection = ScriptedCodexConnection(replies: [
            "initialize": [
                #"{"method":"remoteControl/status/changed","params":{"status":"placeholder"}}"#,
                "not json at all",
                #"{"id":1,"result":{}}"#,
            ],
            "account/rateLimits/read": [
                #"{"method":"remoteControl/status/changed","params":{}}"#,
                #"{"id":2,"method":"account/chatgptAuthTokens/refresh","params":{}}"#,
                #"{"id":7,"result":{"rateLimits":null}}"#,
                rateLimits,
            ],
        ])

        let line = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "dev")

        #expect(String(decoding: line, as: UTF8.self) == rateLimits)
    }

    @Test func waitsForInitializeBeforeSendingTheRequest() async throws {
        let connection = ScriptedCodexConnection(replies: ["initialize": []], finishAfter: "initialize")

        await #expect(throws: CodexAppServerError.exited) {
            _ = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "dev")
        }
        #expect(connection.sentMethods == ["initialize"])
    }

    @Test func errorResponseCarriesTheMessageForClassification() async throws {
        let connection = ScriptedCodexConnection.answering(
            rateLimits: #"{"id":2,"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"}}"#
        )

        await #expect(throws: CodexAppServerError.rpc(method: "account/rateLimits/read", message: "chatgpt authentication required to read rate limits")) {
            _ = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "dev")
        }
    }

    @Test func responseWithoutResultIsMalformed() async throws {
        let connection = ScriptedCodexConnection.answering(rateLimits: #"{"id":2}"#)

        await #expect(throws: CodexAppServerError.malformed) {
            _ = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "dev")
        }
    }

    @Test func serverExitBeforeAnsweringIsReported() async throws {
        let connection = ScriptedCodexConnection(
            replies: ["initialize": [#"{"id":1,"result":{}}"#], "account/rateLimits/read": [#"{"method":"remoteControl/status/changed"}"#]],
            finishAfter: "account/rateLimits/read"
        )

        await #expect(throws: CodexAppServerError.exited) {
            _ = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "dev")
        }
    }
}
