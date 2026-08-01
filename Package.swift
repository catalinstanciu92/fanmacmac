// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FanMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FanMac", targets: ["FanMac"])
    ],
    targets: [
        .target(
            name: "SMCBridge",
            path: "Sources/SMCBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "FanMacCore",
            dependencies: ["SMCBridge"],
            path: "Sources/FanMacCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "FanMac",
            dependencies: ["FanMacCore"],
            path: "Sources/FanMac"
        ),
        .executableTarget(
            name: "FanMacHelper",
            dependencies: ["FanMacCore"],
            path: "Sources/FanMacHelper"
        ),
        .testTarget(
            name: "FanMacTests",
            dependencies: ["FanMacCore"],
            path: "Tests/FanMacTests"
        )
    ]
)
