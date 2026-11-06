// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-voxcpm2: OpenBMB's VoxCPM2 (Apache-2.0 weights; the MLX port, mlx-voxcpm-swift, is MIT, and its engine
// package, mlx-voxcpm2-tts-swift, Apache-2.0) as a Gaea plugin on MES Audio 0.1. One worker executable built on
// GaeaPluginKit, packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// voxcpm2-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, requests and seeding, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-voxcpm2",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.10.0"),
        // 0.6.0: the caller-keyed voice cache MES §13 allows, and metaData's seed (AB-A-0251).
        .package(url: "https://github.com/xocialize/mlx-voxcpm2-tts-swift.git", from: "0.6.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.74.1"),
        // The fleet's mlx-swift fork, as mlx-engine-swift 0.74.1 takes it: 0.32.4 is upstream 0.32.3 plus the
        // _updateInternal leak fix (ml-explore/mlx-swift#501; AB-D-0208). A root line naming ml-explore's URL would win and
        // drop the fix.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.32.4"),
    ],
    targets: [
        .target(
            name: "VoxCPM2Plugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXVoxCPM2TTS", package: "mlx-voxcpm2-tts-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-voxcpm2-worker",
            dependencies: [
                "VoxCPM2Plugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "voxcpm2-inproc",
            dependencies: [
                "VoxCPM2Plugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXVoxCPM2TTS", package: "mlx-voxcpm2-tts-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "VoxCPM2PluginTests", dependencies: ["VoxCPM2Plugin"]),
    ]
)
