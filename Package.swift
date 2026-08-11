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
    ]
)
