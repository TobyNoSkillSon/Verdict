import XCTest
@testable import VerdictKit

/// Wire formats and parsing: no helper needed.
final class WireTests: XCTestCase {
    func testQuestionBuildersMatchWireFormat() {
        XCTAssertEqual(Question.choice("q", ["a": "x", "b": "y"]).json.compact, #"{"type":"choice","instructions":"q","criteria":{"a":"x","b":"y"}}"#)
        XCTAssertEqual(Question.choice("q", labels: ["a", "b"]).json.compact, #"{"type":"choice","instructions":"q","criteria":{"a":"a","b":"b"}}"#)
        XCTAssertEqual(Question.score("q", levels: ["lo", "hi"]).json.compact, #"{"type":"score","instructions":"q","criteria":["lo","hi"]}"#)
        XCTAssertEqual(Question.noul("q").json.compact, #"{"type":"noul","instructions":"q"}"#)
        XCTAssertEqual(Question.noul("q", criteria: ["true": "yes", "false": "no"]).json.compact,
                       #"{"type":"noul","instructions":"q","criteria":{"true":"yes","false":"no"}}"#)
        let questions: Questions = ["z": .noul("first"), "a": .noul("second")]
        XCTAssertEqual(questions.ids, ["z", "a"], "a dictionary literal keeps its order")
    }

    func testQuestionsFileRoundTripKeepsListsNullsAndOrder() throws {
        let text = #"{"kind":{"type":"choice","instructions":"What?","criteria":["b","a"]},"x":{"type":"noul","instructions":"Is it?","criteria":{"true":null,"false":"no"}}}"#
        let questions = try Questions(json: try JSON.parse(text))
        XCTAssertEqual(questions.json.compact, text)
        XCTAssertEqual(questions["kind"]?.labels, ["b", "a"])
        XCTAssertThrowsError(try Questions(json: try JSON.parse(#"{"q":{"type":"nope","instructions":""}}"#))) { error in
            XCTAssertEqual(error.localizedDescription, "Unknown question type 'nope'")
        }
        XCTAssertThrowsError(try Questions(json: .object([])))
        let decoded = try JSONDecoder().decode(Question.self, from: Data(#"{"type":"score","instructions":"q","criteria":["lo","hi"]}"#.utf8))
        XCTAssertEqual(decoded, .score("q", levels: ["lo", "hi"]))
    }

    func testJSONKeepsKeyOrderAndNumberLiterals() throws {
        let text = #"{"b":1,"a":2.0,"c":[1e5,-0.5,true,null],"d":{"é":"x\ny\"\u0001"},"e":"\ud83d\ude00"}"#
        let value = try JSON.parse(text)
        XCTAssertEqual(value.members?.map(\.key), ["b", "a", "c", "d", "e"])
        XCTAssertEqual(value["a"], .number("2.0"))
        XCTAssertEqual(value["e"]?.string, "😀")
        XCTAssertEqual(value.compact, #"{"b":1,"a":2.0,"c":[1e5,-0.5,true,null],"d":{"é":"x\ny\"\u0001"},"e":"😀"}"#)
        // Python json.dumps(ensure_ascii=False) layout, as the CLI's --json prints.
        XCTAssertEqual(value.spaced, #"{"b": 1, "a": 2.0, "c": [1e5, -0.5, true, null], "d": {"é": "x\ny\"\u0001"}, "e": "😀"}"#)
        XCTAssertEqual(try JSON.parse(#"{"a":[]}"#).pretty, "{\n  \"a\": []\n}")
        for bad in ["{", "[1,]", "01", "\"\\x\"", "tru", "{\"a\" 1}", "1 2"] {
            XCTAssertThrowsError(try JSON.parse(bad), bad)
        }
    }

    func testLintFlagsBadShapesOnly() {
        let good: Questions = ["ok": .choice("q", ["a": "x", "other": "none of these"]), "ok2": .noul("Is it remote?"),
                               "ok3": .score("q", levels: ["no deadline", "blocking today"])]
        XCTAssertEqual(good.lint(), [])
        let bad: Questions = ["a": .choice("q", ["a": "x", "b": "y"]), "b": .noul("how many?"), "c": .score("q", levels: ["low", "high"]),
                              "d": .noul("urgent and billing?"), "e": .choice("q", labels: (0..<25).map(String.init))]
        XCTAssertEqual(bad.lint().count, 6)   // 25 options is two problems: count and no escape option
    }

    func testResultsDecode() throws {
        let data = Data(#"{"results":[{"answers":{"dept":{"choice":"billing","confidence":0.9,"probabilities":{"billing":0.9,"other":0.1}},"refund":{"confidence":0.86,"noul":0.86},"urg":{"confidence":0.4,"score":1.6}},"model":"m","ms":6.0},{"error":"too long","model":null,"ms":0}]}"#.utf8)
        struct Reply: Decodable { let results: [Judgement] }
        let results = try JSONDecoder().decode(Reply.self, from: data).results
        XCTAssertEqual(results[0]["dept"]?.choice, "billing")
        XCTAssertEqual(results[0]["dept"]?.probabilities?["other"], 0.1)
        XCTAssertEqual(results[0]["refund"]?.value, 0.86)
        XCTAssertEqual(results[0]["urg"]?.value, 1.6)
        XCTAssertTrue(results[0].ok)
        XCTAssertEqual(results[1].error, "too long"); XCTAssertNil(results[1].model); XCTAssertFalse(results[1].ok)
    }

    /// Review 3 R3.2: ids and labels that differ only by Unicode normalization are distinct, as the API sends them.
    /// Swift's String == and Dictionary fold "é" (U+00E9) and "e\u{301}"; VerdictKit compares exact UTF-8 bytes.
    func testNormalizationDistinctIdsAndLabelsStayDistinct() throws {
        let composed = "\u{E9}", decomposed = "e\u{301}"
        let text = #"{"answers":{"\#u{E9}":{"noul":0.1},"e\u0301":{"noul":0.9},"c":{"choice":"\#u{E9}","confidence":0.7,"probabilities":{"\#u{E9}":0.7,"e\u0301":0.3}}},"model":"m","ms":1}"#
        let judgement = try Judgement(json: try JSON.parse(text))
        XCTAssertEqual(judgement.answers.count, 3)
        XCTAssertEqual(judgement.answers.keys.map { Array($0.utf8) }, [Array(composed.utf8), Array(decomposed.utf8), Array("c".utf8)])
        XCTAssertEqual(judgement[composed]?.noul, 0.1)
        XCTAssertEqual(judgement[decomposed]?.noul, 0.9)
        let probabilities = try XCTUnwrap(judgement["c"]?.probabilities)
        XCTAssertEqual(probabilities.count, 2)
        XCTAssertEqual(probabilities[composed], 0.7); XCTAssertEqual(probabilities[decomposed], 0.3)
        // The raw JSON keeps both members and looks each up by its own bytes.
        let raw = try JSON.parse(text)
        XCTAssertEqual(raw["answers"]?.members?.count, 3)
        XCTAssertEqual(raw["answers"]?[decomposed]?["noul"]?.compact, "0.9")
        XCTAssertEqual(raw["answers"]?[composed]?["noul"]?.compact, "0.1")
        XCTAssertNotEqual(JSON.string(composed), JSON.string(decomposed))
        XCTAssertNotEqual(JSON.object([.init(composed, 1)]), JSON.object([.init(decomposed, 1)]))
        XCTAssertEqual(Set([JSON.string(composed), JSON.string(decomposed)]).count, 2)
        // Questions: two ids, each found by its own bytes.
        let questions: Questions = [composed: .noul("one"), decomposed: .noul("two")]
        XCTAssertEqual(questions.ids.count, 2)
        XCTAssertEqual(questions[decomposed]?.instructions, "two")
        XCTAssertEqual(questions[composed]?.instructions, "one")
        XCTAssertEqual(questions.json.members?.count, 2)
        let file = try Questions(json: try JSON.parse(#"{"\#u{E9}":{"type":"noul","instructions":"one"},"e\u0301":{"type":"noul","instructions":"two"}}"#))
        XCTAssertEqual(file[decomposed]?.instructions, "two")
        // Answers built in code keep both too.
        let built = Judgement(answers: [composed: Answer(noul: 0.1), decomposed: Answer(noul: 0.9)])
        XCTAssertEqual(built.answers.count, 2); XCTAssertEqual(built[decomposed]?.noul, 0.9)
        XCTAssertNotEqual(built, Judgement(answers: [composed: Answer(noul: 0.1), composed: Answer(noul: 0.9)]))
    }

    /// Review 3 re-check: exact keys are unique (first wins, like lookup), so == is symmetric and agrees with hash;
    /// JSONEncoder would fold normalization-distinct keys, so encoding refuses them instead of losing one, and
    /// `json` is the exact serialization.
    func testExactKeyedIsASetOfExactKeysAndNeverEncodesLossily() throws {
        let a: ExactKeyed<Int> = ["x": 1, "x": 1], b: ExactKeyed<Int> = ["x": 1, "y": 2]
        XCTAssertEqual(a.count, 1)
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(b, a)
        let dup: ExactKeyed<Int> = ["x": 1, "x": 2]
        XCTAssertEqual(dup.keys, ["x"]); XCTAssertEqual(dup["x"], 1, "the first entry wins, as in lookup")
        XCTAssertEqual(ExactKeyed([("y", 2), ("x", 1)]), ExactKeyed([("x", 1), ("y", 2)]), "order does not matter")
        XCTAssertEqual(ExactKeyed([("y", 2), ("x", 1)]).hashValue, ExactKeyed([("x", 1), ("y", 2)]).hashValue)
        // Encoding: fine without a collision; a normalization collision is refused, not folded.
        let plain: ExactKeyed<Double> = ["a": 0.5, "b": 0.25]
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).count, #"{"a":0.5,"b":0.25}"#.count)
        let folded: ExactKeyed<Double> = ["\u{E9}": 0.1, "e\u{301}": 0.9]
        XCTAssertThrowsError(try JSONEncoder().encode(folded)) { error in
            XCTAssertTrue("\(error)".contains("normalization"), "\(error)")
        }
        // The exact serialization keeps both.
        let judgement = Judgement(answers: ["\u{E9}": Answer(noul: 0.1), "e\u{301}": Answer(choice: "x", probabilities: folded)], model: "m", ms: 2)
        let json = judgement.json
        XCTAssertEqual(json["answers"]?.members?.count, 2)
        XCTAssertEqual(json["answers"]?["e\u{301}"]?["probabilities"]?.members?.count, 2)
        XCTAssertEqual(try Judgement(json: json), judgement, "round trip")
    }

    func testNotRunningWithoutLaunch() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("verdictkit-empty-\(UUID().uuidString)")
        do {
            _ = try await Verdict(launch: false, supportDirectory: empty)
            XCTFail("found a helper in an empty support directory")
        } catch let error as VerdictError {
            XCTAssertEqual(error, .unavailable("Verdict is not running"))
        }
    }
}

/// The client against a real helper with stub models.
final class HelperTests: XCTestCase {
    var helper: StubHelper!
    var verdict: Verdict!

    override func setUp() async throws {
        helper = try StubHelper()
        verdict = try await Verdict(launch: false, supportDirectory: helper.support)
    }
    override func tearDown() { helper?.stop() }

    func testDiscoveryAndStatus() async throws {
        let status = try await verdict.status()
        XCTAssertEqual(status.api, 1)
        XCTAssertEqual(status.port, helper.port)
        XCTAssertEqual(status.pid.map(Int32.init), helper.process.processIdentifier)
        XCTAssertEqual(status.models, [:])
        XCTAssertEqual(status.on_demand_idle_minutes, 15)
        // The app version (Info.plist; a helper outside an app reads the checkout's Resources/Info.plist).
        let plist = NSDictionary(contentsOf: StubHelper.root.appendingPathComponent("Resources/Info.plist"))
        let version = try XCTUnwrap(plist?["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(status.version, version)
    }

    func testJudgeTypedQuestionsAndPerItemErrors() async throws {
        let questions: Questions = [
            "refund": .noul("Does the customer ask for money back?"),
            "dept": .choice("Which team?", ["billing": "charges, refunds", "tech": "bugs", "other": "none of these"]),
            "urgency": .score("How urgent is this?", levels: ["routine", "this week", "blocking today"]),
        ]
        let long = Array(repeating: "w", count: 9000).joined(separator: " ")
        let items: [Item] = ["please refund me", ["subject": "invoice", "body": "charged twice"], Item(long), ["image": "/tmp/x.png"]]
        let results = try await verdict.judge(items, questions)
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results[0]["refund"]?.noul, 0.75)
        XCTAssertEqual(results[0]["dept"]?.choice, "billing")
        XCTAssertEqual(results[0]["dept"]?.probabilities?.keys.sorted(), ["billing", "other", "tech"])
        XCTAssertEqual(results[0]["urgency"]?.score, 1)
        XCTAssertEqual(results[0].model, "laya-english")
        XCTAssertTrue(results[1].ok)
        XCTAssertTrue(results[2].error?.contains("accepts 8192") == true, "\(results[2])")
        XCTAssertEqual(results[2].model, "laya-english")
        XCTAssertTrue(results[3].error?.contains("judges text") == true)
        XCTAssertNil(results[3].model)
        // Routing: non-ASCII goes to the multilingual model; an explicit model is honoured.
        let routed = try await verdict.judge(["Zażółć gęślą jaźń", "plain"], questions)
        XCTAssertEqual(routed.map(\.model), ["laya-multilingual", "laya-english"])
        let one = try await verdict.judge("plain", ["x": .noul("Is it?")], model: "laya-multilingual")
        XCTAssertEqual(one.model, "laya-multilingual")
        // Batches are split and order is kept.
        let many = try await verdict.judge((0..<10).map { "item \($0)" }, ["x": .noul("Is it?")], batch: 3)
        XCTAssertEqual(many.count, 10)
    }

    /// The live API returns both normalization-distinct ids; the typed and raw results keep both.
    func testLiveJudgeKeepsNormalizationDistinctIds() async throws {
        let questions: Questions = ["\u{E9}": .noul("one"), "e\u{301}": .noul("two")]
        let typed = try await verdict.judge("hello", questions)
        XCTAssertEqual(typed.answers.count, 2, "\(typed)")
        XCTAssertNotNil(typed["e\u{301}"]); XCTAssertNotNil(typed["\u{E9}"])
        let raw = try await verdict.judgeJSON(["hello"], questions: questions.json)
        XCTAssertEqual(raw[0]["answers"]?.members?.count, 2)
    }

    func testJudgeBitsLoadsAtThatPrecision() async throws {
        _ = try await verdict.judge(["x"], ["x": .noul("Is it?")], model: "laya-english", bits: 8)
        var status = try await verdict.status()
        XCTAssertEqual(status.models["laya-english"]?.bits, 8)
        XCTAssertEqual(status.models["laya-english"]?.residency, "on_demand")
        _ = try await verdict.judge(["x"], ["x": .noul("Is it?")], model: "laya-english", bits: 0)
        status = try await verdict.status()
        XCTAssertEqual(status.models["laya-english"]?.bits, 0)
        do {
            _ = try await verdict.judge(["x"], ["x": .noul("Is it?")], model: "laya-english", bits: 5)
            XCTFail("5 bits accepted")
        } catch VerdictError.api(let code, let message) {
            XCTAssertEqual(code, 400)
            XCTAssertEqual(message, "laya-english: Laya precision must be 16, 8 or 4 bits")
        }
        status = try await verdict.status()
        XCTAssertEqual(status.models["laya-english"]?.bits, 0, "a refused precision changes nothing")
    }

    func testLoadUnloadManualAndDelete() async throws {
        let loaded = try await verdict.load("von-1.2", manual: true)
        XCTAssertEqual(loaded, ["von-1.2"])
        var status = try await verdict.status()
        XCTAssertEqual(status.models["von-1.2"]?.residency, "manual")
        XCTAssertEqual(status.models["von-1.2"]?.engineLabel(chip: "M5 Max"), "Optimized · M5 Max")
        _ = try await verdict.load("von-1.2", bits: 8)
        status = try await verdict.status()
        XCTAssertEqual(status.models["von-1.2"]?.bits, 8)
        XCTAssertEqual(status.models["von-1.2"]?.residency, "manual", "a reload keeps a manual model manual")
        let after = try await verdict.unload("von-1.2")
        XCTAssertEqual(after, [])
        do { try await verdict.load("jev"); XCTFail("hosted model loaded") }
        catch VerdictError.api(let code, let message) { XCTAssertEqual(code, 400); XCTAssertTrue(message.contains("hosted"), message) }
        let installed = try await verdict.delete("laya-english")
        XCTAssertEqual(installed, [:])
        let settings = try await verdict.settings(onDemandIdleMinutes: 5, allowSwap: true)
        XCTAssertEqual(settings.on_demand_idle_minutes, 5); XCTAssertEqual(settings.allow_swap, true)
    }

    func testModelsReportPrecisionsAndDeltas() async throws {
        _ = try await verdict.load("von-1.2")
        var models = Dictionary(uniqueKeysWithValues: try await verdict.models().map { ($0.id, $0) })
        let von = try XCTUnwrap(models["von-1.2"])
        XCTAssertEqual(von.state, "hot")
        XCTAssertEqual(von.precision, Model.Precision(selected: 16, default: 16, loaded: 16, options: [32, 16, 8, 4]))
        XCTAssertEqual(von.benchmarks["32"]?.deltas, ["accuracy": "+0.1 pt", "ece": "\u{2212}0.001", "speed": "2.0× slower", "energy": "2.9× more energy"])
        XCTAssertNil(von.benchmarks["16"]?.deltas)
        XCTAssertEqual(von.benchmark, von.benchmarks["16"])
        XCTAssertEqual(models["laya-english"]?.precision?.selected, 16)
        XCTAssertEqual(models["laya-english"]?.state, "available")
        XCTAssertNil(models["jev"]?.precision)
        XCTAssertEqual(models["jev"]?.state, "hosted")
        XCTAssertFalse(models["jev"]?.loadable ?? true)
        XCTAssertNotNil(models["laya-english"]?.links["weights"])
        XCTAssertNil(models["laya-english"]?.links["family"])
        // The app's precision choices (config.json) are what a load uses: explicit choices win.
        try Data(#"{"precision":{"von-1.2":0,"laya-english":8}}"#.utf8).write(to: helper.support.appendingPathComponent("config.json"))
        models = Dictionary(uniqueKeysWithValues: try await verdict.models().map { ($0.id, $0) })
        XCTAssertEqual(models["von-1.2"]?.precision?.selected, 32)
        XCTAssertEqual(models["laya-english"]?.precision?.selected, 8)
    }

    /// Review 3 R3.3: /v1/models precision.selected is exactly what a load without bits uses, including a selection
    /// the app's table saves while the helper runs; explicit bits last while that model stays loaded.
    func testSelectedPrecisionIsWhatALoadWithoutBitsUses() async throws {
        let config = helper.support.appendingPathComponent("config.json")
        func selected(_ id: String) async throws -> Model.Precision? { try await verdict.models().first { $0.id == id }?.precision }
        func loadedBits(_ id: String) async throws -> Int? { try await verdict.status().models[id]?.bits }
        // Nothing chosen: the recommended precision (Laya 16 = native, reported as 0 by /status).
        var p = try await selected("laya-english")
        XCTAssertEqual(p?.selected, p?.default)
        try await verdict.load("laya-english")
        let got1 = try await selected("laya-english")?.loaded
        XCTAssertEqual(got1, p?.selected)
        try await verdict.unload("laya-english")
        // The table picks 4-bit while the helper runs.
        try Data(#"{"precision":{"laya-english":4}}"#.utf8).write(to: config)
        let got2 = try await selected("laya-english")?.selected
        XCTAssertEqual(got2, 4)
        try await verdict.load("laya-english")
        let got3 = try await loadedBits("laya-english")
        XCTAssertEqual(got3, 4)
        // Explicit bits: that load only. After an unload, a plain load is back at the selection.
        try await verdict.load("laya-english", bits: 8)
        p = try await selected("laya-english")
        XCTAssertEqual(p?.selected, 4); XCTAssertEqual(p?.loaded, 8)
        try await verdict.unload("laya-english")
        try await verdict.load("laya-english")
        let got4 = try await loadedBits("laya-english")
        XCTAssertEqual(got4, 4)
        let got5 = try await selected("laya-english")?.selected
        XCTAssertEqual(got5, 4)
        // A judge's on-demand load follows the selection too; a loaded model is not reloaded because the choice changed.
        try await verdict.unload("laya-english")
        try Data(#"{"precision":{"laya-english":8}}"#.utf8).write(to: config)
        _ = try await verdict.judge("x", ["x": .noul("Is it?")], model: "laya-english")
        let got6 = try await loadedBits("laya-english")
        XCTAssertEqual(got6, 8)
        try Data(#"{"precision":{"laya-english":4}}"#.utf8).write(to: config)
        _ = try await verdict.judge("x", ["x": .noul("Is it?")], model: "laya-english")
        p = try await selected("laya-english")
        XCTAssertEqual(p?.selected, 4); XCTAssertEqual(p?.loaded, 8)
        // A saved choice the model cannot run is ignored by both, not half-applied.
        try await verdict.unload("laya-english")
        try Data(#"{"precision":{"laya-english":7}}"#.utf8).write(to: config)
        p = try await selected("laya-english")
        XCTAssertEqual(p?.selected, p?.default)
        try await verdict.load("laya-english")
        let got7 = try await selected("laya-english")?.loaded
        XCTAssertEqual(got7, p?.default)
    }

    /// A launch environment choice (VERDICT_PRECISION: test and benchmark harnesses) wins over config.json in both.
    func testLaunchPrecisionOverridesConfigInModelsAndLoads() async throws {
        helper.stop()
        helper = try StubHelper(environment: ["VERDICT_PRECISION": #"{"von-1.2":8}"#])
        verdict = try await Verdict(launch: false, supportDirectory: helper.support)
        try Data(#"{"precision":{"von-1.2":4}}"#.utf8).write(to: helper.support.appendingPathComponent("config.json"))
        let got8 = try await verdict.models().first { $0.id == "von-1.2" }?.precision?.selected
        XCTAssertEqual(got8, 8)
        try await verdict.load("von-1.2")
        let got9 = try await verdict.status().models["von-1.2"]?.bits
        XCTAssertEqual(got9, 8)
    }

    /// Review 3 R3.6: precisions and minutes are whole numbers; 4.9 is refused (400), never truncated to 4, and the
    /// loaded model is unchanged.
    func testFractionalAndNonNumericIntegersAreRefused() async throws {
        try await verdict.load("laya-english", bits: 8)
        for bad in ["4.9", "16.9", "true", "\"4.5\"", "[4]"] {
            var (code, body) = try await helper.raw("POST", "/v1/load", body: #"{"model":"laya-english","bits":"# + bad + "}")
            XCTAssertEqual(code, 400, bad); XCTAssertEqual(body["error"] as? String, "bits must be a whole number, not \(bad)")
            (code, body) = try await helper.raw("POST", "/v1/judge", body: #"{"items":["x"],"questions":{"x":{"type":"noul","instructions":"q"}},"model":"laya-english","bits":"# + bad + "}")
            XCTAssertEqual(code, 400, bad)
            (code, _) = try await helper.raw("POST", "/v1/settings", body: #"{"on_demand_idle_minutes":"# + bad + "}")
            XCTAssertEqual(code, 400, bad)
        }
        let status = try await verdict.status()
        XCTAssertEqual(status.models["laya-english"]?.bits, 8, "a refused precision changes nothing")
        XCTAssertEqual(status.on_demand_idle_minutes, 15)
        // Integral values in any JSON spelling are whole numbers; the app's string form still works; null bits = omitted.
        for good in ["4", "4.0", "\"4\"", "4e0"] {
            let (code, body) = try await helper.raw("POST", "/v1/load", body: #"{"model":"laya-english","bits":"# + good + "}")
            XCTAssertEqual(code, 200, "\(good): \(body)")
            let got10 = try await verdict.status().models["laya-english"]?.bits
            XCTAssertEqual(got10, 4, good)
        }
        let (code, _) = try await helper.raw("POST", "/v1/load", body: #"{"model":"laya-english","bits":null}"#)
        XCTAssertEqual(code, 200)
        let got11 = try await verdict.status().models["laya-english"]?.bits
        XCTAssertEqual(got11, 4, "null bits leaves a loaded model as it is")
    }

    func testRoutesStatusCodesAndSecurity() async throws {
        var (code, body) = try await helper.raw("GET", "/status")
        XCTAssertEqual(code, 200); XCTAssertEqual(body["api"] as? Int, 1, "the unversioned alias serves the same status")
        (code, _) = try await helper.raw("GET", "/v1/status?x=1")
        XCTAssertEqual(code, 200)
        (code, body) = try await helper.raw("POST", "/v1/nope", body: "{}")
        XCTAssertEqual(code, 404); XCTAssertEqual(body["error"] as? String, "not found: POST /v1/nope")
        (code, _) = try await helper.raw("POST", "/v1/quit", body: "{}")
        XCTAssertEqual(code, 404, "internal endpoints are not versioned")
        (code, _) = try await helper.raw("GET", "/models")
        XCTAssertEqual(code, 404, "new endpoints are /v1 only")
        (code, body) = try await helper.raw("GET", "/v1/judge")
        XCTAssertEqual(code, 404); XCTAssertEqual(body["error"] as? String, "/v1/judge takes POST")
        (code, body) = try await helper.raw("POST", "/v1/judge", body: #"{"items":["x"],"questions":{"x":{"type":"noul","instructions":"q"}}}"#,
                                            headers: ["Content-Type": "application/json", "Origin": "https://example.com"])
        XCTAssertEqual(code, 403); XCTAssertEqual(body["error"] as? String, "cross-origin requests are not accepted")
        (code, body) = try await helper.raw("POST", "/v1/judge", body: "{}", headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(code, 415); XCTAssertEqual(body["error"] as? String, "Content-Type must be application/json")
        (code, body) = try await helper.raw("POST", "/v1/judge", body: #"{"items":[],"questions":{}}"#)
        XCTAssertEqual(code, 400); XCTAssertEqual(body["error"] as? String, "items must be a nonempty list")
        (code, body) = try await helper.raw("POST", "/v1/judge", body: "{not json")
        XCTAssertEqual(code, 400)
    }

    func testMemoryRefusalIs507WithTheReason() async throws {
        helper.stop()
        let memory = FileManager.default.temporaryDirectory.appendingPathComponent("verdictkit-memory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: memory) }
        try Data(#"{"available_mb": 100}"#.utf8).write(to: memory)
        helper = try StubHelper(environment: ["VERDICT_TEST_MEMORY_FILE": memory.path])
        verdict = try await Verdict(launch: false, supportDirectory: helper.support)
        do { try await verdict.load("laya-english"); XCTFail("loaded without memory") }
        catch VerdictError.api(let code, let message) {
            XCTAssertEqual(code, 507)
            XCTAssertTrue(message.hasPrefix("laya-english at 16-bit needs ~"), message)
        }
        let status = try await verdict.status()
        XCTAssertEqual(status.refused?.model, "laya-english")
    }
}
