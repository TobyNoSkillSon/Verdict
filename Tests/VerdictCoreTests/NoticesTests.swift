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
                     "Runtime Library Exception", "The SwiftCrypto Project",
                     // Review 3 re-check N1: vendored MLX code with its own notice (MLX's ACKNOWLEDGMENTS.md omits them).
                     "Copyright © 2018 the V8 project authors.", "Copyright (c) 2015-2023 Norbert Juffa",
                     "SPDX-FileCopyrightText: 2009 Florian Loitsch", "Copyright (c) 2009 Florian Loitsch",
                     "SPDX-FileCopyrightText: 2008-2009 Björn Hoehrmann", "SPDX-FileCopyrightText: 2016-2021 Evan Nemerson",
                     "SPDX-FileCopyrightText: 2018 The Abseil Authors"] {
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

    /// Review 3 re-check N1: every copyright holder named in a vendored C, C++ or Metal source of the pinned checkouts
    /// (MLX, mlx-c, fmt, nlohmann/json, metal-cpp, the generated JIT kernels, yyjson) is named in the notices. Apple's
    /// own headers are covered by the package licences. Tests, fuzzers and docs are not compiled and are skipped.
    func testEveryVendoredCopyrightHolderIsInTheNotices() throws {
        let checkouts = Self.root.appendingPathComponent(".build/checkouts")
        guard FileManager.default.fileExists(atPath: checkouts.appendingPathComponent("mlx-swift/Source/Cmlx").path) else {
            throw XCTSkip("no .build/checkouts (run swift package resolve)")
        }
        // fmt's LICENSE writes "{fmt} contributors", its headers "fmt contributors".
        let notices = try text("Resources/THIRD_PARTY_NOTICES.txt").replacingOccurrences(of: "{fmt}", with: "fmt")
        // "Copyright (c) 2012 - present, Victor Zverovich" → "Victor Zverovich"; also SPDX-FileCopyrightText lines.
        let line = try NSRegularExpression(pattern: #"(?:Copyright\s*(?:©|\([cC]\)|@)?\s*(?=\d)|SPDX-FileCopyrightText:\s*)([^<\n]*)"#)
        let lead = try NSRegularExpression(pattern: #"^[\d\s,\-–]*(?:present,?\s*)?"#)
        let skipped = ["/test/", "/tests/", "/docs/", "/doc/", "/benchmarks/", "/examples/", "/python/", "/backend/cuda/"]
        var missing: [String: String] = [:], scanned = 0
        for tree in ["mlx-swift/Source/Cmlx", "yyjson/src"] {
            let base = checkouts.appendingPathComponent(tree)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in files where ["h", "hpp", "c", "cc", "cpp", "metal", "m", "mm"].contains(url.pathExtension) {
                let rel = tree + "/" + url.path.dropFirst(base.path.count + 1)
                if skipped.contains(where: rel.contains) { continue }
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                for m in line.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    var holder = String(source[Range(m.range(at: 1), in: source)!])
                    holder = lead.stringByReplacingMatches(in: holder, range: NSRange(holder.startIndex..., in: holder), withTemplate: "")
                    holder = holder.replacingOccurrences(of: "All rights reserved.", with: "").replacingOccurrences(of: "{fmt}", with: "fmt")
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,")))
                    if holder.isEmpty || holder.hasPrefix("Apple") || notices.contains(holder) { continue }
                    missing[holder] = missing[holder] ?? rel
                }
            }
        }
        XCTAssertGreaterThan(scanned, 300, "the scan found the vendored sources")
        XCTAssertEqual(missing, [:], "copyright holders absent from THIRD_PARTY_NOTICES.txt (add them to scripts/third-party-notices.py)")
    }

    /// Review 3 re-check N5: the release zip has no AppleDouble (._*) or __MACOSX entries, and an app extracted
    /// with /usr/bin/unzip still verifies. scripts/release-zip.sh makes and checks the archive for package-release.sh;
    /// here it runs on a small ad-hoc signed app carrying an extended attribute (a stand-in for com.apple.provenance).
    func testReleaseZipHasNoAppleDoubleAndVerifiesAfterUnzip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("verdict-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let app = tmp.appendingPathComponent("Probe.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Probe").path)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>CFBundleExecutable</key><string>Probe</string>
            <key>CFBundleIdentifier</key><string>test.verdict.probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
            """.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("notice\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/NOTICE"))
        func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
            p.standardOutput = pipe; p.standardError = pipe
            try p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, out)
        }
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]).0, 0)
        for f in ["Contents/Resources/NOTICE", "Contents/Info.plist", "Contents/MacOS/Probe"] {
            XCTAssertEqual(try run("/usr/bin/xattr", ["-w", "com.example.verdict-test", "1", app.appendingPathComponent(f).path]).0, 0)
        }
        let script = Self.root.appendingPathComponent("scripts/release-zip.sh").path
        // The archive the old `ditto -c -k --keepParent` wrote: ._ entries, and the unzipped app fails verification.
        let old = tmp.appendingPathComponent("old.zip").path
        XCTAssertEqual(try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, old]).0, 0)
        XCTAssertTrue(try run("/usr/bin/zipinfo", ["-1", old]).1.contains("/._NOTICE"), "precondition: ditto keeps xattrs as ._ files")
        let rejected = try run("/bin/bash", [script, "--verify", old])
        XCTAssertNotEqual(rejected.0, 0, rejected.1)
        XCTAssertTrue(rejected.1.contains("AppleDouble"), rejected.1)
        // The archive release-zip.sh writes: no ._ or __MACOSX entries; the /usr/bin/unzip extraction verifies.
        let zip = tmp.appendingPathComponent("Probe.zip").path
        let made = try run("/bin/bash", [script, app.path, zip])
        XCTAssertEqual(made.0, 0, made.1)
        let listing = try run("/usr/bin/zipinfo", ["-1", zip]).1.split(separator: "\n")
        XCTAssertTrue(listing.contains("Probe.app/Contents/Resources/NOTICE"), "\(listing)")
        XCTAssertFalse(listing.contains { $0.contains("/._") || $0.hasPrefix("._") || $0.hasPrefix("__MACOSX") }, "\(listing)")
        let out = tmp.appendingPathComponent("unzipped")
        XCTAssertEqual(try run("/usr/bin/unzip", ["-q", zip, "-d", out.path]).0, 0)
        let verified = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", out.appendingPathComponent("Probe.app").path])
        XCTAssertEqual(verified.0, 0, verified.1)
        let package = try text("scripts/package-release.sh")
        XCTAssertTrue(package.contains("scripts/release-zip.sh"), "package-release.sh builds the archive with release-zip.sh")
        XCTAssertFalse(package.contains("ditto -c -k --keepParent"), "no archive with extended attributes")
    }

    /// 0.3.0 is stated once, in Info.plist; the build number is a whole number that only goes up.
    func testVersionIsStatedInInfoPlist() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist")))
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.3.0")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "3")
        for doc in ["README.md", "AGENTS.md", "Resources/SKILL.md", "docs/API.md", "docs/USAGE.md"] {
            XCTAssertNil(try text(doc).range(of: #"\b0\.2\.0\b"#, options: .regularExpression), "\(doc) states the old version")
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
