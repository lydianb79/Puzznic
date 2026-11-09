// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PuzznicRemastered",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PuzznicRemastered", targets: ["PuzznicRemastered"]),
    ],
    targets: [
        .target(
            name: "NESCore",
            path: "Sources/NESCore"
        ),
        .executableTarget(
            name: "PuzznicRemastered",
            dependencies: ["NESCore"],
            path: "Sources/PuzznicRemastered",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("GameController"),
            ]
        ),
    ]
)
