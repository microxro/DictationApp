// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DictationApp",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(name: "Dictation", targets: ["Dictation"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1")
    ],
    targets: [
        .target(
            name: "Dictation",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: ".",
            sources: [
                "App/AudioCapture.swift",
                "App/Cleaner.swift",
                "App/ContentView.swift",
                "App/DictationEngine.swift",
                "App/Transcriber.swift",
                "Shared/Shared.swift"
            ]
        ),
        .testTarget(
            name: "DictationTests",
            dependencies: ["Dictation"],
            path: "Tests"
        )
    ]
)
