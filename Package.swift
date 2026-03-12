// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Stay",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Stay", targets: ["Stay"]),
        .executable(name: "WakeCycleScenarios", targets: ["WakeCycleScenarios"]),
    ],
    targets: [
        .target(
            name: "StayCore"
        ),
        .target(
            name: "WakeCycleScenariosCore"
        ),
        .executableTarget(
            name: "Stay",
            dependencies: ["StayCore"]
        ),
        .executableTarget(
            name: "WakeCycleScenarios",
            dependencies: ["WakeCycleScenariosCore", "StayCore"]
        ),
        .testTarget(
            name: "StayCoreTests",
            dependencies: ["StayCore"]
        ),
        .testTarget(
            name: "WakeCycleScenariosCoreTests",
            dependencies: ["WakeCycleScenariosCore"]
        ),
        .testTarget(
            name: "StayIntegrationTests",
            dependencies: ["StayCore", "Stay"]
        ),
    ]
)
