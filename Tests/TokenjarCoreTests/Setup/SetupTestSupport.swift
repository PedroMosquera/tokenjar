import Foundation

/// A throwaway home directory, so setup tests never depend on what is installed on the machine running them.
struct TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "tokenjar-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url.appending(path: relative), withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ contents: String, permissions: Int? = nil) throws {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
    }

    func copyFixture(_ name: String, to relative: String) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/Setup/\(name)")
        try write(relative, String(decoding: try Data(contentsOf: fixture), as: UTF8.self))
    }
}
