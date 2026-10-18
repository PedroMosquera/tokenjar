import Testing
@testable import TokenjarCore

/// Stored checkpoint and dedupe keys are these digests, so every platform must produce CryptoKit's exact output.
struct SHA256Tests {
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        // 56 bytes: the length no longer fits in the first block, so padding spills into a second.
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        (
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        ),
        ("/Users/someone/.claude/projects/-Users-someone-wörk/ñ.jsonl", "bb7822839f6a227eaa362044c25f227849ff130c0f8ffa4ccf37555aa8d60d33"),
    ])
    func matchesKnownDigests(input: String, digest: String) {
        #expect(sha256Hex(input) == digest)
    }

    @Test func millionAs() {
        #expect(sha256Hex(String(repeating: "a", count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
