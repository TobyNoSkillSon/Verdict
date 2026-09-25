// swift-tools-version: 5.9
import PackageDescription

// Build with scripts/build.sh (app) or scripts/build-helper.sh (helper + Metal library): Swift is compiled
// with the stable Command Line Tools Swift 6.3.3, mlx-swift's shaders with Xcode's Metal Toolchain
// (MTL_FAST_MATH=NO). The dependency pins below are the parity-proven set; changing any of them
// requalifies the Laya/Von parity gate.
let package = Package(
    name: "Verdict",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Verdict", targets: ["Verdict"]),
        .executable(name: "verdict-helper", targets: ["verdict-helper"])
    ],
    dependencies: [
        // Laya 9×202 parity-qualified only with core 0.32.2 + precise Metal shaders.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", revision: "901941965d82e4a216d4d117231d847d194c563d"),
        // Token ids and all nine Laya fixture sets were qualified with 1.3.4.
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
        // Qualified together with Tokenizers 1.3.4 under stable CLT Swift 6.3.3.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.0")
    ],
    targets: [
        // Menu-bar app: UI and helper supervision. No MLX dependency.
        .executableTarget(name: "Verdict", dependencies: ["VerdictCore"]),
        // App logic shared with tests: catalog, precision, memory, labels.
        .target(name: "VerdictCore"),
        // Models (Laya, Von), tokenizers and attention on MLX.
        .target(name: "VerdictEngine", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        // The helper process the app launches: loopback HTTP service over VerdictEngine.
        .executableTarget(name: "verdict-helper", dependencies: ["VerdictEngine", "VerdictCore", .product(name: "MLX", package: "mlx-swift")],
                          path: "Sources/VerdictHelper"),
        .testTarget(name: "VerdictCoreTests", dependencies: ["VerdictCore"])
    ]
)
