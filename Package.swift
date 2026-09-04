// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IOSVirtualDeviceLab",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "IOSVirtualDeviceLab", targets: ["IOSVirtualDeviceLab"]),
        .executable(name: "vdlctl", targets: ["VDLCLI"]),
        .executable(name: "vdl-ui-smoke", targets: ["VDLUISmoke"]),
        .executable(name: "vdl-fleetd", targets: ["VDLFleetCoordinator"]),
        .executable(name: "vdl-fleetworker", targets: ["VDLFleetWorker"]),
    ],
    targets: [
        .executableTarget(
            name: "IOSVirtualDeviceLab",
            path: "Sources/IOSVirtualDeviceLab"
        ),
        .testTarget(
            name: "IOSVirtualDeviceLabTests",
            dependencies: ["IOSVirtualDeviceLab"],
            path: "Tests/IOSVirtualDeviceLabTests"
        ),
        .executableTarget(
            name: "VDLCLI",
            path: "Sources/VDLCLI"
        ),
        .executableTarget(
            name: "VDLUISmoke",
            path: "Sources/VDLUISmoke"
        ),
        .executableTarget(
            name: "VDLFleetCoordinator",
            path: "Sources/VDLFleetCoordinator"
        ),
        .executableTarget(
            name: "VDLFleetWorker",
            path: "Sources/VDLFleetWorker"
        ),
    ]
)
