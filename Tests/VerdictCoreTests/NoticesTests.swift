import XCTest

/// Review 3 R3.1: the app must carry Verdict's LICENSE and NOTICE and the licences of every linked package
/// (Resources/THIRD_PARTY_NOTICES.txt, written by scripts/third-party-notices.py), and build.sh must ship them.
final class NoticesTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func text(_ path: String) throws -> String { try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8) }
    /// Trailing whitespace is not content (the generator strips it).
    func normalized(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }.joined(separator: "\n")
    }

    func testNoticeNamesVerdictAndTheNativePorts() throws {
        let notice = try text("NOTICE")
        XCTAssertTrue(notice.hasPrefix("Verdict\n"), notice)
        XCTAssertFalse(notice.contains("Anubis"))
        XCTAssertFalse(notice.contains("using the laya-mlx runtime"), "Verdict ports laya-mlx; it does not run it")
        for credit in ["laya-mlx 0.2.0", "Convai Innovations", "von-sdk", "Victor Hugo Panisa", "Hugging Face tokenizers",
                       "THIRD_PARTY_NOTICES.txt", "bundles no model weights"] {
            XCTAssertTrue(notice.contains(credit), credit)
        }
        XCTAssertTrue(try text("LICENSE").contains("Apache License"))
    }

    func testThirdPartyNoticesCoverEveryResolvedPackage() throws {
        let notices = try text("Resources/THIRD_PARTY_NOTICES.txt")
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("Package.resolved"))) as? [String: Any]
        let pins = try XCTUnwrap(resolved?["pins"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(pins.count, 10)
        for pin in pins {
            let identity = try XCTUnwrap(pin["identity"] as? String)
            let revision = try XCTUnwrap((pin["state"] as? [String: Any])?["revision"] as? String)
            XCTAssertTrue(notices.contains("  package  \(identity) "), identity)
            XCTAssertTrue(notices.contains(revision), "\(identity) at the pinned revision \(revision)")
        }
        // MIT/BSD/zlib copyright lines must be reproduced, including code MLX vendors; the Runtime Library Exception kept.
        for line in ["Copyright (c) 2023 ml-explore", "Copyright © 2023 Apple Inc.", "Niels Lohmann", "Victor Zverovich",
                     "Max-Planck-Society", "Jakob Progsch", "NVIDIA Corporation", "YaoYuan", "Copyright 2025 Mattt",
                     "Runtime Library Exception", "The SwiftCrypto Project"] {
            XCTAssertTrue(notices.contains(line), line)
        }
    }

    /// When the pinned checkouts are present (any built tree), each licence file is in the notices verbatim.
    func testNoticesMatchTheCheckouts() throws {
        let checkouts = Self.root.appendingPathComponent(".build/checkouts")
        guard FileManager.default.fileExists(atPath: checkouts.appendingPathComponent("mlx-swift/LICENSE").path) else {
            throw XCTSkip("no .build/checkouts (run swift package resolve)")
        }
        let notices = normalized(try text("Resources/THIRD_PARTY_NOTICES.txt"))
        for file in ["mlx-swift/LICENSE", "mlx-swift/Source/Cmlx/mlx/LICENSE", "mlx-swift/Source/Cmlx/mlx-c/LICENSE",
                     "mlx-swift/Source/Cmlx/fmt/LICENSE", "mlx-swift/Source/Cmlx/json/LICENSE.MIT", "mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt",
                     "swift-numerics/LICENSE.txt", "swift-transformers/LICENSE", "swift-jinja/LICENSE", "swift-huggingface/LICENSE",
                     "EventSource/LICENSE.md", "yyjson/LICENSE", "swift-collections/LICENSE.txt", "swift-crypto/NOTICE.txt",
                     "swift-crypto/LICENSE.txt", "swift-asn1/NOTICE.txt", "swift-asn1/LICENSE.txt"] {
            let licence = try String(contentsOf: checkouts.appendingPathComponent(file), encoding: .utf8)
            let body = normalized(licence).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(notices.contains(body), "\(file) is not reproduced verbatim; rerun scripts/third-party-notices.py")
        }
    }

    /// build.sh copies the three files into Contents/Resources and refuses to finish without them.
    func testBuildShipsTheNotices() throws {
        let build = try text("scripts/build.sh")
        XCTAssertTrue(build.contains("LICENSE NOTICE Resources/THIRD_PARTY_NOTICES.txt"), "copied into the bundle")
        XCTAssertTrue(build.contains("Contents/Resources/$f"), "checked in the bundle before signing")
        XCTAssertTrue(try text("scripts/package-release.sh").contains("THIRD_PARTY_NOTICES.txt"), "archive-content check")
    }
}
