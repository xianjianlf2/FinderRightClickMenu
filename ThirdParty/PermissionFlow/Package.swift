// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PermissionFlow",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PermissionFlow", targets: ["PermissionFlow"]),
        .library(name: "SystemSettingsKit", targets: ["SystemSettingsKit"]),
    ],
    targets: [
        .target(
            name: "SystemSettingsKit",
            path: "Sources/SystemSettingsKit"
        ),
        .target(
            name: "PermissionFlow",
            dependencies: ["SystemSettingsKit"],
            path: "Sources/PermissionFlow",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
