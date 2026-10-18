// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tokenjar",
    platforms: [.macOS(.v14)],
    targets: [
        // Linux has no SQLite3 module in its SDK; macOS uses the SDK's and never builds this one.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "TokenjarCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
            linkerSettings: [.linkedLibrary("sqlite3")]
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
#endif
