// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "verdict-helper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "verdict-helper", targets: ["verdict-helper"])],
    dependencies: [
        // Laya 9×202 parity-qualified only with core 0.32.2 + precise Metal shaders.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", revision: "901941965d82e4a216d4d117231d847d194c563d"),
        // Token ids and all nine Laya fixture sets were qualified with 1.3.4.
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
        // Qualified together with Tokenizers 1.3.4 under stable CLT Swift 6.3.3.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.0")
    ],
    targets: [
        .target(name: "VerdictEngine", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        .executableTarget(name: "verdict-helper", dependencies: ["VerdictEngine", .product(name: "MLX", package: "mlx-swift")], path: "Sources/VerdictHelper")
    ]
)
