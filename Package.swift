// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tokenjar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tokenjar", targets: ["Tokenjar"]),
    ],
    targets: [
        .target(
            name: "TokenjarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Tokenjar",
            dependencies: ["TokenjarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "TokenjarCoreTests",
            dependencies: ["TokenjarCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "TokenjarTests",
            dependencies: ["Tokenjar", "TokenjarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
