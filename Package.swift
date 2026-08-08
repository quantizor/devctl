// swift-tools-version: 6.2
import PackageDescription

let strictCore: [SwiftSetting] = [
    .defaultIsolation(nil)
]

let package = Package(
    name: "devctl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "devctl", targets: ["devctl"]),
        .executable(name: "devctld", targets: ["devctld"]),
        .executable(name: "DevCtlApp", targets: ["DevCtlApp"]),
        .executable(name: "fixture-server", targets: ["fixture-server"]),
        .library(name: "DevCtlKit", targets: ["DevCtlKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        /** Pre-1.0: pinned to the exact commit of tag 0.5 (the tag is not full semver, so a
            revision pin is the strictest available). Isolated behind ProcessLauncher. */
        .package(url: "https://github.com/swiftlang/swift-subprocess", revision: "11633673a41f509f8945f23c96c7acd4adafd679"),
    ],
    targets: [
        .target(
            name: "DevCtlKit",
            swiftSettings: strictCore
        ),
        .target(
            name: "DevCtlDaemonCore",
            dependencies: [
                "DevCtlKit",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strictCore
        ),
        .executableTarget(
            name: "devctld",
            dependencies: ["DevCtlDaemonCore", "DevCtlKit"],
            exclude: ["Info.plist"],
            swiftSettings: strictCore,
            linkerSettings: [
                /** Embedded Info.plist for the helper Mach-O identity. Login
                    Items naming for the app install path comes from
                    SMAppService + the responsible app, not this section. */
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/devctld/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "devctl",
            dependencies: [
                "DevCtlKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictCore
        ),
        .executableTarget(
            name: "DevCtlApp",
            dependencies: ["DevCtlKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),
        .executableTarget(
            name: "fixture-server",
            swiftSettings: strictCore
        ),
        .testTarget(
            name: "DevCtlKitTests",
            dependencies: ["DevCtlKit"]
        ),
        .testTarget(
            name: "DevCtlDaemonCoreTests",
            dependencies: ["DevCtlDaemonCore", "DevCtlKit"]
        ),
        /** The CLI's argument parsing is behavior with a contract (docs/cli-contract.md)
            and no other way to exercise it: a parse defect there silently changes
            what a guarded command receives. */
        .testTarget(
            name: "DevCtlCLITests",
            dependencies: [
                "DevCtlKit",
                "devctl",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["DevCtlKit"]
        ),
    ]
)
