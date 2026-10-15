import Foundation
import Testing
import TokenjarCore

struct FixtureShapeTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")

    @Test func fixturesCarryNoSecrets() throws {
        let files = try Self.files(under: Self.folder)
        #expect(files.count >= 60, "the scan found only \(files.count) files")
        for file in files {
            let findings = Self.secretFindings(in: try String(contentsOf: file, encoding: .utf8))
            #expect(findings.isEmpty, "\(file.path.dropFirst(Self.folder.path.count + 1)): \(findings)")
        }
    }

    /// Key-shaped values are joined at run time so this file never holds one a secret scanner would flag.
    @Test(arguments: ["sk-ant-api03-", "ghp_", "gho_", "oc_sk_"].map { $0 + "Zq8vT2mWbX4kLp9nRc7dYs1fHj6gEu3a" } + [
        "someone@company.com", "3f9c2a71-8b4e-4d6f-a1c3-9e7b5d2f0a84", "/Users/someone/src/project",
    ])
    func theSecretCheckCatchesAPlantedValue(_ planted: String) {
        #expect(!Self.secretFindings(in: "{\"value\": \"\(planted)\"}").isEmpty)
    }

    @Test func theSecretCheckLetsPlaceholdersThrough() {
        let text = """
            {"email": "member-1@example.invalid", "uuid": "00000000-0000-0000-0000-000000000001", "cwd": "/Users/placeholder/src",
             "home": "/Users/PLACEHOLDER/.claude", "key": "sk-ant-API_KEY_PLACEHOLDER_VALUE", "token": "ghp_REDACTED_REDACTED_REDACTED",
             "note": "a legacy (non oc_sk_) key"}
            """
        #expect(Self.secretFindings(in: text).isEmpty)
    }

    /// One finding per line that holds an email outside example.invalid, a key prefix followed by real-looking text, a
    /// UUID that is not a placeholder, or a home folder other than `/Users/placeholder`, which the Claude and Codex logs
    /// use. Values are left out, so a real secret never lands in a log.
    static func secretFindings(in text: String) -> [String] {
        let email = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
        let key = /(sk-ant-|ghp_|gho_|oc_sk_)[A-Za-z0-9_-]{16,}/
        let uuid = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        let home = /\/Users\/[^\/\s"]+/
        var findings: [String] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineName = "line \(index + 1)"
            if line.matches(of: email).contains(where: { !$0.output.lowercased().hasSuffix("@example.invalid") }) {
                findings.append("\(lineName): email")
            }
            if line.matches(of: key).contains(where: { match in
                let value = match.output.0.uppercased()
                return !value.contains("PLACEHOLDER") && !value.contains("REDACTED")
            }) {
                findings.append("\(lineName): key")
            }
            // A real UUID uses most hex digits; a placeholder such as 00000000-0000-0000-0000-000000000001 uses one or two.
            if line.matches(of: uuid).contains(where: { Set($0.output.lowercased().filter(\.isHexDigit)).count > 2 }) {
                findings.append("\(lineName): uuid")
            }
            if line.matches(of: home).contains(where: { $0.output.lowercased() != "/users/placeholder" }) {
                findings.append("\(lineName): home folder")
            }
        }
        return findings
    }

    private static func files(under folder: URL) throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }
}
