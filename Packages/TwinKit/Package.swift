// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TwinKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TwinKit", targets: ["TwinKit"]),
    ],
    targets: [
        .target(name: "TwinModels"),
        .target(name: "TwinNetworking", dependencies: ["TwinModels"]),
        .target(name: "TwinAuth", dependencies: ["TwinModels", "TwinNetworking"]),
        .target(name: "TwinProfile", dependencies: ["TwinModels", "TwinNetworking"]),
        .target(name: "TwinAvailability", dependencies: ["TwinModels", "TwinNetworking"]),
        .target(name: "TwinKit", dependencies: [
            "TwinModels",
            "TwinNetworking",
            "TwinAuth",
            "TwinProfile",
            "TwinAvailability",
        ]),
        .testTarget(name: "TwinKitTests", dependencies: [
            "TwinModels",
            "TwinNetworking",
            "TwinAuth",
            "TwinProfile",
            "TwinAvailability",
        ]),
    ]
)
