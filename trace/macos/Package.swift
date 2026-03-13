// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RTMifyTraceMacOSTests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "RTMifyTraceMacOSSupport", targets: ["RTMifyTraceMacOSSupport"]),
    ],
    targets: [
        .target(
            name: "RTMifyTraceMacOSSupport",
            path: "RTMify Trace",
            exclude: [
                "App.swift",
                "ContentView.swift",
                "DoneView.swift",
                "DropZoneView.swift",
                "LicenseGateView.swift",
                "RTMifyBridge.swift",
                "Assets.xcassets",
                "Info.plist",
                "rtmify-bridge.h",
            ],
            sources: [
                "ViewModel.swift",
            ]
        ),
        .testTarget(
            name: "RTMifyTraceMacOSSupportTests",
            dependencies: ["RTMifyTraceMacOSSupport"],
            path: "Tests/RTMifyTraceMacOSSupportTests"
        ),
    ]
)
