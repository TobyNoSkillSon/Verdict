import XCTest
@testable import VerdictKit
@testable import VerdictCLI

/// `verdict diagnose`: the report format, the issue URL builder, and the built binary against a stub helper.
final class DiagnoseFormatTests: XCTestCase {
    func loaded(_ json: String) throws -> Status.LoadedModel { try JSONDecoder().decode(Status.LoadedModel.self, from: Data(json.utf8)) }

    static let host = Diagnosis.Host(chip: "M4 Pro", architecture: "applegpu_g16s", macos: "15.5", neuralAccelerators: false,
                                     hardware: "Mac16,7", memoryGB: 48)

    func testReportOptimizedAndPartlyOptimizedModels() throws {
        let fast = try loaded(#"{"bits":0,"engine":"optimized","residency":"manual","kernel":"windowed-attention (L>=768, self-test max diff 1.2e-06)","optimizations":{"tokenizer":"fast","attention":"windowed","matmul":"standard GPU","optimized":false}}"#)
        let slow = try loaded(#"{"bits":16,"engine":"mlx","engine_reason":"kernel self-test did not pass on this chip","residency":"on_demand","kernel":"stock (windowed-attention self-test failed)","optimizations":{"tokenizer":"fast","attention":"stock","matmul":"standard GPU","optimized":false}}"#)
        let precision = try JSONDecoder().decode(Model.Precision.self, from: Data(#"{"selected":16,"default":16,"loaded":16,"options":[16,8,4]}"#.utf8))
        let a = Diagnose.report(id: "laya-english", state: fast, precision: precision, chip: "M4 Pro",
                                timing: .init(singleMs: 9.44, longMs: 31.2, batchPerSecond: 412.6), answers: .init(valid: 20, agreed: 19, total: 20, errors: []), error: nil)
        let b = Diagnose.report(id: "von-1.2", state: slow, precision: nil, chip: "M4 Pro", timing: nil, answers: nil, error: "von-1.2: HTTP 500")
        let d = Diagnosis(cliVersion: "0.3.0", appVersion: "0.3.0", api: 1, mlx: "0.32.0 (mlx-swift 9019419)", host: Self.host,
                          running: true, models: [a, b])
        XCTAssertEqual(Diagnose.text(d), [
            "verdict diagnose",
            "verdict 0.3.0 (app 0.3.0, API 1) · MLX 0.32.0 (mlx-swift 9019419)",
            "Mac: M4 Pro · Mac16,7 · 48 GB · macOS 15.5 · GPU applegpu_g16s, neural accelerators no",
            "laya-english: Optimized · M4 Pro · 16-bit (recommended) · manual",
            "  paths: tokenizer fast, attention windowed, matmul standard GPU",
            "  self-test: passed (windowed-attention (L>=768, self-test max diff 1.2e-06))",
            "  fallbacks: matmul: standard GPU (no neural accelerators on this chip or macOS)",
            "  timing: 9.4 ms single (p50 of 18), 31 ms long item (>1k tokens), 413 items/s batched (20 per request)",
            "  answers: 20/20 valid; refund as expected on 19/20",
            "von-1.2: MLX · 16-bit · on demand",
            "  paths: tokenizer fast, attention stock, matmul standard GPU",
            "  self-test: failed (stock (windowed-attention self-test failed))",
            "  fallbacks: kernel self-test did not pass on this chip; matmul: standard GPU (no neural accelerators on this chip or macOS)",
            "  not timed: von-1.2: HTTP 500"])
        XCTAssertEqual(Diagnose.title(d), "M4 Pro, macOS 15.5: von-1.2 on MLX: kernel self-test did not pass on this chip")
        let json = Diagnose.json(d, issueURL: "u")
        XCTAssertEqual(json["models"]?.array?.first?["timing"]?["single_ms_p50"]?.double, 9.44)
        XCTAssertEqual(json["models"]?.array?.last?["fallbacks"]?.array?.count, 2)
        XCTAssertEqual(json["issue_url"]?.string, "u")
    }

    func testNotRunningAndNothingLoaded() {
        var d = Diagnosis(cliVersion: "0.3.0", host: Self.host, running: false, models: [])
        XCTAssertEqual(Diagnose.text(d).last, "Verdict is not running: start it (menu bar, or `open -g /Applications/Verdict.app`) and run `verdict diagnose` again.")
        XCTAssertEqual(Diagnose.text(d)[1], "verdict 0.3.0")
        XCTAssertEqual(Diagnose.title(d), "M4 Pro, macOS 15.5: Verdict not running")
        d.running = true
        XCTAssertTrue(Diagnose.text(d).last!.hasPrefix("no model loaded: nothing timed. `verdict diagnose --load` loads laya-english"))
    }

    func testSelfTestAndChecks() throws {
        XCTAssertEqual(Diagnose.selfTest(nil), "not reported")
        XCTAssertEqual(Diagnose.selfTest("stock (windowed attention switched off after an inference failure)"),
                       "passed at load; stock (windowed attention switched off after an inference failure)")
        XCTAssertEqual(Diagnose.items.count, 20)
        XCTAssertEqual(Diagnose.items.filter(\.refund).count, 10)
        // The long items exceed the windowed-attention threshold (768 tokens) even if every word and symbol were one token.
        let pieces = try NSRegularExpression(pattern: #"\w+|[^\w\s]"#).numberOfMatches(in: Diagnose.orderLog, range: NSRange(Diagnose.orderLog.startIndex..., in: Diagnose.orderLog))
        XCTAssertGreaterThan(pieces, 1000)
        let good = try JSON.parse(#"{"answers":{"refund":{"noul":0.9},"kind":{"probabilities":{"billing":0.8,"other":0.2}},"urgency":{"score":1.2}}}"#)
        let nan = try JSON.parse(#"{"answers":{"refund":{"noul":0.2},"kind":{"probabilities":{"billing":2}},"urgency":{"score":1}}}"#)
        let error = try JSON.parse(#"{"error":"too long"}"#)
        let answers = Diagnose.check([good, nan, error] + Array(repeating: good, count: 17))
        // good agrees on item 0 (yes) and on the 9 later yes items among 17; nan is item 1 (no, 0.2) and agrees.
        XCTAssertEqual(answers.valid, 18)
        XCTAssertEqual(answers.errors, ["too long"])
        XCTAssertEqual(answers.agreed, 1 + 1 + Diagnose.items[3...].filter(\.refund).count)
    }
}

final class IssueURLTests: XCTestCase {
    func query(_ url: String) throws -> [String: String] {
        let items = try XCTUnwrap(URLComponents(string: url)?.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testShortReportIsCarriedWhole() throws {
        let body = "verdict diagnose\nMac: M3 · macOS 15.1\nlaya-english: MLX & more?=#"
        let url = IssueURL.bugReport(repository: "https://github.com/o/r", title: "M3: laya-english on MLX",
                                     fields: [("chip", "M3, Mac15,3"), ("macos", "15.1"), ("version", "")], diagnose: body, maxLength: 7000)
        XCTAssertTrue(url.hasPrefix("https://github.com/o/r/issues/new?template=bug_report.yml&title="), url)
        let q = try query(url)
        XCTAssertEqual(q["template"], "bug_report.yml")
        XCTAssertEqual(q["title"], "M3: laya-english on MLX")
        XCTAssertEqual(q["chip"], "M3, Mac15,3")
        XCTAssertEqual(q["macos"], "15.1")
        XCTAssertNil(q["version"], "empty fields are left out")
        XCTAssertEqual(q["diagnose"], body)
        XCTAssertFalse(url.contains(" ") || url.contains("\n") || url.contains("·"))
    }

    func testLongReportIsCutAtALineWithinTheLimit() throws {
        let lines = (0..<400).map { "line \($0): tokenizer fast · attention windowed · ✓ é" }
        let body = lines.joined(separator: "\n")
        for limit in [7000, 2000, 700] {
            let url = IssueURL.bugReport(repository: "https://github.com/o/r", title: "t", fields: [("chip", "M1")], diagnose: body, maxLength: limit)
            XCTAssertLessThanOrEqual(url.count, limit)
            let value = try XCTUnwrap(query(url)["diagnose"], "percent escapes are intact")
            XCTAssertTrue(value.hasSuffix(IssueURL.truncationNote), value)
            let kept = String(value.dropLast(IssueURL.truncationNote.count))
            XCTAssertTrue(body.hasPrefix(kept + "\n"), "whole lines only")
            XCTAssertGreaterThan(kept.split(separator: "\n").count, 0)
        }
    }

    func testOneHugeLineIsCutByCharacters() throws {
        let body = String(repeating: "ž", count: 5000)
        let url = IssueURL.bugReport(repository: "https://github.com/o/r", title: "t", fields: [], diagnose: body, maxLength: 1000)
        XCTAssertLessThanOrEqual(url.count, 1000)
        let value = try XCTUnwrap(query(url)["diagnose"])
        XCTAssertTrue(value.hasSuffix(IssueURL.truncationNote))
        XCTAssertTrue(value.dropLast(IssueURL.truncationNote.count).allSatisfy { $0 == "ž" })
    }

    func testRepositoryAndTemplateMatchTheForm() throws {
        let form = try String(contentsOf: StubHelper.root.appendingPathComponent(".github/ISSUE_TEMPLATE/\(IssueURL.template)"), encoding: .utf8)
        for id in ["diagnose", "chip", "macos", "version"] { XCTAssertTrue(form.contains("id: \(id)\n"), "the form has field \(id)") }
        XCTAssertEqual(Diagnose.repository, "https://github.com/TobyNoSkillSon/Verdict")
    }
}

final class DiagnoseBinaryTests: XCTestCase {
    var helper: StubHelper!
    override func setUpWithError() throws { helper = try StubHelper() }
    override func tearDown() { helper?.stop() }

    func run(_ args: [String]) throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = CLIBinaryTests.binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["VERDICT_SUPPORT_DIR"] = helper.support.path
        env["VERDICT_APP"] = "/nonexistent/Verdict.app"
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let watchdog = StubHelper.watchdog(process); defer { watchdog.cancel() }
        let out = stdout.fileHandleForReading.readDataToEndOfFile(), err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    func testDiagnoseLoadsOnlyWhenAsked() throws {
        guard FileManager.default.isExecutableFile(atPath: CLIBinaryTests.binary.path) else { throw XCTSkip("verdict-cli not built") }
        var r = try run(["diagnose"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("no model loaded: nothing timed"), r.out)
        XCTAssertTrue(r.out.contains("· MLX "), "the helper reports its MLX version")
        XCTAssertTrue(r.out.contains("https://github.com/TobyNoSkillSon/Verdict/issues/new?template=bug_report.yml"), r.out)
        XCTAssertFalse(try run(["status"]).out.contains("laya-english"), "diagnose loads nothing by default")

        r = try run(["diagnose", "--load", "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let json = try JSON.parse(r.out)
        XCTAssertEqual(json["loaded_for_diagnosis"]?.string, "laya-english")
        let model = try XCTUnwrap(json["models"]?.array?.first)
        XCTAssertEqual(model["id"]?.string, "laya-english")
        XCTAssertEqual(model["self_test"]?.string, "passed (windowed-attention (stub))")
        XCTAssertEqual(model["answers"]?["valid"]?.int, 20)
        XCTAssertGreaterThan(model["timing"]?["batch_items_per_s"]?.double ?? 0, 0)
        XCTAssertTrue(json["mlx"]?.string?.contains("mlx-swift 9019419") == true, r.out)

        r = try run(["diagnose", "extra"])
        XCTAssertEqual(r.code, 1); XCTAssertEqual(r.err, "error: unexpected argument extra\n")
    }
}
