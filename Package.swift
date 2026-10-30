// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hermes",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "Hermes",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
