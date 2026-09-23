// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Verdict", platforms: [.macOS(.v14)], products: [.executable(name: "Verdict", targets: ["Verdict"])], targets: [
    .target(name: "VerdictCore"),
    .executableTarget(name: "Verdict", dependencies: ["VerdictCore"]),
    .testTarget(name: "VerdictCoreTests", dependencies: ["VerdictCore"])
])
