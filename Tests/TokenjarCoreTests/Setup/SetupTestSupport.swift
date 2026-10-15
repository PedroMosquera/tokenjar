import Foundation

/// A throwaway home directory, so setup tests never depend on what is installed on the machine running them.
struct TempHome {
    private let directory = TemporaryDirectory()
    var url: URL { directory.url }

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
        try write(relative, fixtureText("Setup/\(name)"))
    }
}
