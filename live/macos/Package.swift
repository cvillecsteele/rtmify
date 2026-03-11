// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RTMifyLiveMacOSTests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "RTMifyLiveMacOSSupport", targets: ["RTMifyLiveMacOSSupport"]),
    ],
    targets: [
        .target(
            name: "RTMifyLiveMacOSSupport",
            path: "RTMify Live",
            exclude: [
                "App.swift",
                "ViewModel.swift",
                "LicenseGateView.swift",
                "MenuBarView.swift",
                "Assets.xcassets",
                "Info.plist",
                "Resources",
            ],
            sources: [
                "PortSelection.swift",
                "CrashSupervisor.swift",
                "OutputRingBuffer.swift",
            ]
        ),
        .testTarget(
            name: "RTMifyLiveMacOSSupportTests",
            dependencies: ["RTMifyLiveMacOSSupport"],
            path: "Tests/RTMifyLiveMacOSSupportTests"
        ),
    ]
)
