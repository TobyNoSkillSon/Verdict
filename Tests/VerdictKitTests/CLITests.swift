import XCTest
@testable import VerdictKit
@testable import VerdictCLI

/// `verdict` output formats (one short plain line per fact) and the built binary against a stub helper.
final class CLIFormatTests: XCTestCase {
    func status(_ json: String) throws -> Status { try JSONDecoder().decode(Status.self, from: Data(json.utf8)) }

    func testStatusShowsEngineLabelAndReason() throws {
        let s = try status(#"{"port":1,"calls":0,"last_ms":null,"memory":{},"gpu":{"chip":"M5 Max"},"models":{"laya-english":{"device":"mlx","engine":"optimized"},"von-1.2":{"device":"mlx","engine":"mlx","engine_reason":"kernel self-test did not pass on this chip"}}}"#)
        let text = Format.status(s).joined(separator: "\n")
        XCTAssertTrue(text.contains("laya-english (Optimized · M5 Max)"), text)
        XCTAssertTrue(text.contains("von-1.2 (MLX: kernel self-test did not pass on this chip)"), text)
    }

    func testStatusShowsResidencyKeepHotAndRefusal() throws {
        let refusal = "von-1.2 at 16-bit needs ~2.0 GB; ~0.9 GB free without swapping. Unload laya-english, pick 8-bit, or allow swap in Verdict → Memory."
        let s = try status(#"{"port":1,"calls":0,"last_ms":null,"memory":{"available_mb":900},"gpu":{"chip":"M5 Max"},"models":{"laya-english":{"device":"mlx","engine":"optimized","residency":"manual"}},"manual_idle_minutes":0,"on_demand_idle_minutes":15,"allow_swap":false,"evictions":[{"model":"laya-multilingual","residency":"on_demand","reason":"memory: made room for von-1.2 at 16-bit","at":1}],"refused":{"model":"von-1.2","message":""# + refusal + #"","at":2}}"#)
        let text = Format.status(s).joined(separator: "\n")
        XCTAssertTrue(text.contains("laya-english (Optimized · M5 Max) [manual]"), text)
        XCTAssertTrue(text.contains("~0.9 GB free now"), text)
        XCTAssertTrue(text.contains("keep hot: manual always, on demand 15 min idle  memory: fit in free memory"), text)
        XCTAssertTrue(text.contains("unloaded laya-multilingual (on demand): memory: made room for von-1.2 at 16-bit"), text)
        XCTAssertTrue(text.contains("refused: " + refusal), text)
    }

    func testStatusWithNothingLoadedReadsPlainly() throws {
        let s = try status(#"{"port":1,"calls":0,"last_ms":null,"memory":{"rss_mb":31,"mlx_active_mb":0,"available_mb":84900},"models":{},"manual_idle_minutes":0,"on_demand_idle_minutes":15,"allow_swap":true}"#)
        XCTAssertEqual(Format.status(s), [
            "port 1  models: none loaded (a judge loads its model on demand)  calls: 0  memory: 31 MB rss, 0 MB weights, ~84.9 GB free now",
            "keep hot: manual always, on demand 15 min idle  memory: allow swap"])
        let busy = try status(#"{"port":7,"calls":3,"last_ms":5,"memory":{"rss_mb":900.4,"mlx_active_mb":812.6},"models":{},"loading":"von-1.2","error":"x: y"}"#)
        XCTAssertEqual(Format.status(busy), ["port 7  models: none loaded (a judge loads its model on demand)  calls: 3  last: 5 ms  memory: 900 MB rss, 813 MB weights  loading: von-1.2  error: x: y"])
    }

    func testEngineLabelMatchesTheApp() throws {
        func label(_ json: String, _ chip: String?) throws -> String {
            try JSONDecoder().decode(Status.LoadedModel.self, from: Data(json.utf8)).engineLabel(chip: chip)
        }
        XCTAssertEqual(try label(#"{"engine":"optimized"}"#, "M5 Max"), "Optimized · M5 Max")
        XCTAssertEqual(try label(#"{"engine":"optimized"}"#, nil), "Optimized")
        XCTAssertEqual(try label(#"{"engine":"mlx","engine_reason":"tokenizer format not recognised"}"#, "M5 Max"), "MLX")
        XCTAssertEqual(try label(#"{"optimizations":{"tokenizer":"fast","attention":"windowed"}}"#, "M4"), "Optimized · M4")
        XCTAssertEqual(try label(#"{"optimizations":{"tokenizer":"library","attention":"windowed"}}"#, "M4"), "MLX")
        XCTAssertEqual(try label(#"{"device":"mlx"}"#, nil), "MLX")
    }

    func testJudgeLine() throws {
        let result = try JSON.parse(#"{"answers":{"b":{"noul":0.754},"a":{"choice":"billing","confidence":0.9}},"model":"m","ms":1}"#)
        XCTAssertEqual(Format.line(index: 3, item: "refund\nplease", result: result, field: nil, order: ["a", "b"]),
                       "#3  a=billing(0.90)  b=0.75  | refund please")
        let item = try JSON.parse(#"{"id":1,"body":"x"}"#)
        XCTAssertEqual(Format.line(index: 0, item: item, result: result, field: nil, order: ["b", "a"]),
                       #"#0  b=0.75  a=billing(0.90)  | {"id": 1, "body": "x"}"#)
        XCTAssertEqual(Format.line(index: 0, item: item, result: result, field: "body", order: ["b"]), "#0  b=0.75  a=billing(0.90)  | x")
        XCTAssertEqual(Format.line(index: 1, item: "x", result: try JSON.parse(#"{"error":"too long","model":null,"ms":0}"#), field: nil, order: []),
                       "#1  error: too long")
        let long = String(repeating: "é", count: 80)
        XCTAssertEqual(Format.line(index: 0, item: .string(long), result: result, field: nil, order: ["a"]).hasSuffix("| " + String(repeating: "é", count: 60)), true)
    }

    func testPrecisionRowsAndInfo() throws {
        let model = try JSONDecoder().decode(Model.self, from: Data(#"""
        {"id":"von-1.2","name":"Von 1.2","family":"Von","inputs":["text"],"params":"0.4B","context":8192,"languages":"en","license":"apache-2.0",
         "state":"hot","loadable":true,"precision":{"selected":16,"default":16,"loaded":16,"options":[32,16,8,4]},
         "benchmark":{"accuracy":0.479,"ece":0.1,"ms":7.43,"j_per_1k":345.5,"memory_mb":1200,"sets":{"b":0.5,"a":0.25},"n_tasks":25,"source":"measured","n":2100,"date":"2026-09-25","hardware":"M5 Max","items_per_s":800,"accuracy_en":0.5},
         "benchmarks":{"32":{"accuracy":0.48,"ece":0.099,"ms":15.2,"j_per_1k":1050.2,"memory_mb":2100,"deltas":{"accuracy":"+0.1 pt","ece":"−0.001","speed":"2.0× slower","energy":"2.9× more energy"}},
                       "16":{"accuracy":0.479,"ece":0.1,"ms":7.43,"j_per_1k":345.5,"memory_mb":1200}},
         "links":{"weights":"https://huggingface.co/x","upstream":"https://github.com/y"},"recommendation":"English and multilingual"}
        """#.utf8))
        XCTAssertEqual(Format.precisionRows(model), [
            "  32  48.0% +0.1 pt    0.099 −0.001    15 ms 2.0× slower    1050 J 2.9× more energy   2.10 GB",
            "  16  47.9%            0.100           7.4 ms               346 J                     1.20 GB  recommended, selected, loaded",
            "   8  —                —               —                    —                               —",
            "   4  —                —               —                    —                               —"])
        XCTAssertEqual(Format.info(model), [
            "Von 1.2 (von-1.2) — hot",
            "  family      Von    licence apache-2.0",
            "  inputs      text    context 8192 tokens    languages en    params 0.4B",
            "  bits  accuracy         ece             speed                energy/1k                  memory"] + Format.precisionRows(model).map { "  " + $0 } + [
            "  tasks       a 25.0%, b 50.0%  (25 tasks)",
            "  split       English 50.0%",
            "  source      measured, n=2100, 2026-09-25, M5 Max; batched 800 items/s",
            "  use for     English and multilingual",
            "  upstream    https://github.com/y",
            "  weights     https://huggingface.co/x"])
        let table = Format.table([model])
        XCTAssertEqual(table[0], "model                  inputs           context bits accuracy    ece    speed   J/1k   memory  state      weights")
        XCTAssertEqual(table[1], "von-1.2                text                8192   16    47.9%  0.100   7.4 ms    346  1.20 GB  hot        https://huggingface.co/x")
    }
}

final class CLIBinaryTests: XCTestCase {
    var helper: StubHelper!
    override func setUpWithError() throws { helper = try StubHelper() }
    override func tearDown() { helper?.stop() }

    /// The verdict-cli product built next to this test bundle.
    static var binary: URL { Bundle(for: CLIBinaryTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("verdict-cli") }

    func run(_ args: [String], input: String = "") throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["VERDICT_SUPPORT_DIR"] = helper.support.path
        env["VERDICT_APP"] = "/nonexistent/Verdict.app"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile(), err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    func testCommands() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.binary.path) else { throw XCTSkip("verdict-cli not built at \(Self.binary.path)") }
        var r = try run(["status"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.hasPrefix("port \(helper.port)  models: none loaded (a judge loads its model on demand)  calls: 0"), r.out)
        XCTAssertTrue(r.out.contains("keep hot: manual always, on demand 15 min idle  memory: fit in free memory"), r.out)

        let questions = helper.support.appendingPathComponent("q.json")
        try Data(#"{"x": {"type": "noul", "instructions": "Is this about billing?"}}"#.utf8).write(to: questions)
        let items = (0..<6).map { #"{"id": \#($0), "body": "item \#($0)"}"# }.joined(separator: "\n")
        r = try run(["judge", "--questions", questions.path, "--field", "body", "--sort", "x", "--top", "3", "--min", "0.5", "--json"], input: items)
        XCTAssertEqual(r.code, 0, r.err)
        let rows = try r.out.split(separator: "\n").map { try JSON.parse(String($0)) }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].members?.map(\.key), ["index", "item", "answers", "model", "ms"])
        XCTAssertEqual(rows.map { $0["index"]?.int }, [0, 1, 2], "equal scores keep input order")
        XCTAssertEqual(rows[0]["item"]?.compact, #"{"id":0,"body":"item 0"}"#)
        r = try run(["judge", "--questions", questions.path, "--field", "body"], input: items)
        XCTAssertEqual(r.out.split(separator: "\n").first, "#0  x=0.75  | item 0")
        r = try run(["judge", "--questions", questions.path, "--min", "0.9", "--sort", "x"], input: items)
        XCTAssertEqual(r.out, "")
        r = try run(["judge", "--bogus"])
        XCTAssertEqual(r.code, 1); XCTAssertEqual(r.err, "error: unknown option --bogus\n")
        r = try run(["judge", "--questions", questions.path, "--sort", "nope"], input: items)
        XCTAssertEqual(r.code, 1); XCTAssertTrue(r.err.contains("--sort nope is not a question"), r.err)

        r = try run(["load", "laya-english", "--bits", "8"])
        XCTAssertEqual(r.code, 0, r.err); XCTAssertEqual(r.out, "['laya-english']\n")
        r = try run(["load", "laya-english", "--bits", "5"])
        XCTAssertEqual(r.code, 1); XCTAssertEqual(r.err, "error: laya-english: Laya precision must be 16, 8 or 4 bits\n")
        r = try run(["load", "von-1.2", "--manual"])
        XCTAssertEqual(r.out, "['laya-english', 'von-1.2']\n")
        r = try run(["status"])
        XCTAssertTrue(r.out.contains("von-1.2 (Optimized"), r.out); XCTAssertTrue(r.out.contains("[manual]"), r.out)
        r = try run(["unload", "von-1.2"])
        XCTAssertEqual(r.out, "['laya-english']\n")

        r = try run(["models"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.hasPrefix("model                  inputs           context bits accuracy"), r.out)
        XCTAssertTrue(r.out.contains("\nlaya-english "), r.out)
        XCTAssertTrue(r.out.contains("hot "), "laya-english is loaded")
        r = try run(["models", "--all"])
        XCTAssertTrue(r.out.contains("recommended"), r.out)
        r = try run(["models", "--json"])
        XCTAssertEqual(try JSON.parse(r.out).array?.first?.members?.first?.key, "benchmark")
        r = try run(["info", "laya-english"])
        XCTAssertTrue(r.out.hasPrefix("Laya · English (laya-english) — hot"), r.out)
        r = try run(["info", "nope"])
        XCTAssertEqual(r.err, "error: unknown model 'nope'; see verdict models\n")

        r = try run(["skill"])
        XCTAssertTrue(r.out.hasPrefix("---\nname: triage"), r.out)
        r = try run(["skill", "--install", helper.support.appendingPathComponent("skills").path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.support.appendingPathComponent("skills/triage/SKILL.md").path))
        r = try run(["--help"])
        XCTAssertTrue(r.out.contains("verdict judge --questions"), r.out)
    }
}
