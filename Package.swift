// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Debrief",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DebriefApp", targets: ["DebriefApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(name: "Store", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Transcriber", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
        .target(name: "CoachingEngine", dependencies: ["Store"]),
        .target(name: "CaptureKit", dependencies: []),
        .executableTarget(
            name: "DebriefApp",
            dependencies: ["Store", "Transcriber", "CoachingEngine", "CaptureKit"]
        ),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
        .testTarget(name: "TranscriberTests", dependencies: ["Transcriber"]),
        .testTarget(name: "CoachingEngineTests", dependencies: ["CoachingEngine", "Store"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(name: "DebriefAppTests", dependencies: ["DebriefApp"]),
    ]
)
