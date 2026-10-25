// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TempMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TempMonitor",
            path: "Sources/TempMonitor",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Metal"), .linkedLibrary("IOReport")]
        ),
        .testTarget(
            name: "TempMonitorTests",
            dependencies: ["TempMonitor"],
            path: "Tests/TempMonitorTests"
        ),
    ]
)
