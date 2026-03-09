// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Stay",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Stay", targets: ["Stay"])
    ],
    targets: [
        .target(
            name: "StayCore"
        ),
        .executableTarget(
            name: "Stay",
            dependencies: ["StayCore"]
        ),
        .testTarget(
            name: "StayCoreTests",
            dependencies: ["StayCore"]
        )
    ]
)
