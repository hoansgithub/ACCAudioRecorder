// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ACCAudioRecorder",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ACCAudioRecorder",
            targets: ["ACCAudioRecorder"]
        )
    ],
    targets: [
        .target(
            name: "ACCAudioRecorder",
            dependencies: [],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
