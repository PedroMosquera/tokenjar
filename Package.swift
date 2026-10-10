// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Headroom", targets: ["Headroom"]),
    ],
    targets: [
        .target(
            name: "HeadroomCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Headroom",
            dependencies: ["HeadroomCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "HeadroomCoreTests",
            dependencies: ["HeadroomCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
