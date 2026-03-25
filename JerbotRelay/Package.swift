// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JerbotRelay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JerbotRelay",
            path: "Sources/JerbotRelay",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
