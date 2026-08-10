// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KAIInstaller",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "KAIInstallerCore", targets: ["KAIInstallerCore"]),
        .executable(name: "KAIInstallerApp", targets: ["KAIInstallerApp"]),
        .executable(name: "kai-installer-cli", targets: ["KAIInstallerCLI"]),
    ],
    targets: [
        .target(name: "KAIInstallerCore"),
        .executableTarget(
            name: "KAIInstallerApp",
            dependencies: ["KAIInstallerCore"]
        ),
        .executableTarget(
            name: "KAIInstallerCLI",
            dependencies: ["KAIInstallerCore"]
        ),
    ]
)
