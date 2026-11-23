// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PACore", targets: ["PACore"]),
        .library(name: "PAMock", targets: ["PAMock"]),
    ],
    targets: [
        .target(
            name: "PACore",
            path: "Sources/PACore"
        ),
        .target(
            name: "PAMock",
            path: "Sources/PAMock"
        ),
        .executableTarget(
            name: "PAApp",
            dependencies: ["PACore"],
            path: "Sources/PAApp"
        ),
        .executableTarget(
            name: "mock-llm",
            dependencies: ["PAMock"],
            path: "Sources/mock-llm"
        ),
        .testTarget(
            name: "PACoreTests",
            dependencies: ["PACore", "PAMock"],
            path: "Tests/PACoreTests"
        ),
    ]
)
