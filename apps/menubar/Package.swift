// swift-tools-version: 6.0
// LocalCron menu bar app. Built with `swift build`; scripts/build-app.sh
// assembles LocalCron.app around it with the Rust binaries.
import PackageDescription

let package = Package(
    name: "LocalCron",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalCron", targets: ["LocalCron"]),
    ],
    targets: [
        // Everything that can be tested without a UI: API types, daemon
        // client, updater logic, installers.
        .target(name: "LocalCronKit"),
        .executableTarget(name: "LocalCron", dependencies: ["LocalCronKit"]),
        .testTarget(name: "LocalCronKitTests", dependencies: ["LocalCronKit"]),
    ]
)
