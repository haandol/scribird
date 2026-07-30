// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scribird",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Scribird",
            path: "Sources/Scribird",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags([
                    "-Xfrontend", "-enable-actor-data-race-checks",
                ], .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "ScribirdTests",
            dependencies: ["Scribird"],
            path: "Tests/ScribirdTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
