import Foundation
import Testing

/// Hard rule 2 in docs/design.md: nothing in the app can read, write or prompt for a Keychain item.
struct NoKeychainTests {
    static let forbidden = ["import Security", "SecItem", "SecKeychain", "kSecClass", "/usr/bin/security"]

    @Test func noSourceFileCanReachTheKeychain() throws {
        let sources = TestPaths.repository.appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            offenders += Self.forbidden.filter(text.contains).map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
