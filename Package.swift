// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tokenjar",
    platforms: [.macOS(.v14)],
    targets: [
        // Only macOS has an SQLite3 module in its SDK; elsewhere this wraps the system library. Windows 10 and later
        // ship theirs as winsqlite3.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "TokenjarCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux, .windows]))],
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS, .linux])),
                .linkedLibrary("winsqlite3", .when(platforms: [.windows])),
            ]
        ),
        .testTarget(
            name: "TokenjarCoreTests",
            dependencies: ["TokenjarCore"],
            exclude: ["Fixtures"]
        ),
    ]
)

// The app is AppKit and SwiftUI, so elsewhere only the core and its tests build.
#if os(macOS)
package.products.append(.executable(name: "Tokenjar", targets: ["Tokenjar"]))
package.targets += [
    .executableTarget(
        name: "Tokenjar",
        dependencies: ["TokenjarCore"],
        swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
        name: "TokenjarTests",
        dependencies: ["Tokenjar", "TokenjarCore"],
        swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
]
#else
// A console `tokenjar` for checks and scripts, and on Windows a tray app beside it.
package.products.append(.executable(name: "tokenjar", targets: ["TokenjarCLI"]))
package.targets.append(.executableTarget(name: "TokenjarCLI", dependencies: ["TokenjarCore"]))
#if os(Windows)
package.products.append(.executable(name: "TokenjarTray", targets: ["TokenjarTray"]))
package.targets.append(.executableTarget(
    name: "TokenjarTray",
    dependencies: ["TokenjarCore"],
    linkerSettings: [
        // A GUI program, so starting it opens no console. Swift's entry point is still main, which the C runtime calls.
        .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
        .linkedLibrary("user32"), .linkedLibrary("gdi32"), .linkedLibrary("shell32"), .linkedLibrary("advapi32"),
    ]
))
#endif
#endif
