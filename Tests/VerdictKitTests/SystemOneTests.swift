import Foundation
import XCTest
@testable import VerdictKit

/// SystemOneClient offline: request encoding against the official Python SDK's bytes, response parsing, errors.
final class SystemOneWireTests: XCTestCase {
    /// typesafe-sdk 0.7.1 `prepare_system_one` for the same state and questions (Noul, Noul with criteria, Choice with
    /// a null description, Score), model "auto"; and a structured state/instructions call with extra_body {"bits": 8}.
    func testRequestBodyMatchesTheTypeSafeSDK() throws {
        let questions: Questions = [
            "billing": .noul("Is this about billing?"),
            "strict": .noul("Refund?", criteria: ["true": "asks for money back", "false": "anything else"]),
            "tone": .choice("What is the tone?", options: ["calm": nil, "angry": "upset or hostile"]),
            "urgency": .score("How urgent is this?", levels: ["low", "medium", "high"]),
        ]
        let body = try SystemOneClient.body(state: "I was charged twice.", questions: questions, model: "auto")
        XCTAssertEqual(body.compact, #"{"state":"I was charged twice.","model":"auto","questions":{"billing":{"type":"noul","instructions":"Is this about billing?"},"strict":{"type":"noul","instructions":"Refund?","criteria":{"true":"asks for money back","false":"anything else"}},"tone":{"type":"choice","instructions":"What is the tone?","criteria":{"calm":null,"angry":"upset or hostile"}},"urgency":{"type":"score","instructions":"How urgent is this?","criteria":["low","medium","high"]}}}"#)
        let structured = try Questions(json: JSON.parse(#"{"q":{"type":"noul","instructions":{"task":"t","data":[1,2]}}}"#))
        XCTAssertNotNil(structured["q"]?.verbatim, "structured instructions are kept as sent")
        let extra = try SystemOneClient.body(state: .object([.init("subject", "x"), .init("n", 2)]), questions: structured, model: "laya-english",
                                             extraBody: [.init("bits", 8)])
        XCTAssertEqual(extra.compact, #"{"state":{"subject":"x","n":2},"model":"laya-english","questions":{"q":{"type":"noul","instructions":{"task":"t","data":[1,2]}}},"bits":8}"#)
        XCTAssertThrowsError(try SystemOneClient.body(state: "x", questions: [:], model: "auto"))
        XCTAssertThrowsError(try SystemOneClient.body(state: "x", questions: ["s": .score("?", levels: [])], model: "auto"))
    }

    func testDefaults() {
        let local = SystemOneClient()
        XCTAssertNil(local.baseURL); XCTAssertEqual(local.model, "auto"); XCTAssertEqual(local.apiKey, "verdict")
        let remote = SystemOneClient(baseURL: URL(string: "https://openrouter.ai/api/")!, apiKey: " k \n", model: "jev-1.13")
        XCTAssertEqual(remote.baseURL?.absoluteString, "https://openrouter.ai/api")
        XCTAssertEqual(remote.apiKey, "k"); XCTAssertEqual(remote.model, "jev-1.13")
    }

    func testResultParsingAndTypedAccessors() throws {
        let data = Data(#"""
        {"model":"laya-english","usage":{"input_tokens":109,"output_tokens":0},"id":"gen-1","answers":{
          "billing":{"type":"noul","noul":0.93},
          "tone":{"type":"choice","choice":"angry","confidence":0.72,"probabilities":{"angry":0.95,"calm":0.05}},
          "urgency":{"type":"score","score":1.65,"confidence":0.31,"legend":{"0":"low","1":"medium","2":{"level":"high"}},"probabilities":{"0":0.06,"1":0.23,"2":0.71}},
          "future":{"type":"ranking","order":[1,2]}}}
        """#.utf8)
        let r = try SystemOneResult(data: data, requestID: "req_1")
        XCTAssertEqual(r.model, "laya-english"); XCTAssertEqual(r.inputTokens, 109); XCTAssertEqual(r.requestID, "req_1")
        XCTAssertEqual(r.nouls["billing"]?.noul, 0.93)
        XCTAssertEqual(r.choices["tone"]?.choice, "angry")
        XCTAssertEqual(r.choices["tone"]?.probabilities["calm"], 0.05)
        XCTAssertEqual(r.scores["urgency"]?.score, 1.65)
        XCTAssertEqual(r.scores["urgency"]?.legend[2], .object([.init("level", "high")]))
        XCTAssertEqual(r.scores["urgency"]?.probabilities[2], 0.71)
        XCTAssertEqual(r.answers.count, 3, "an unknown answer type is skipped")
        XCTAssertEqual(r.nouls.count, 1); XCTAssertEqual(r.choices.count, 1); XCTAssertEqual(r.scores.count, 1)
        XCTAssertNotNil(r.raw["answers"]?["future"])
    }

    func testWrongTypedResponsesThrow() {
        let bad = [
            #"{"model":"m","usage":{},"answers":{"a":{"type":"noul","noul":"0.9"}}}"#,
            #"{"model":"m","usage":{},"answers":{"a":{"type":"choice","choice":"x","confidence":1,"probabilities":{"x":null}}}}"#,
            #"{"model":"m","usage":{},"answers":{"a":{"type":"score","score":1,"confidence":1,"probabilities":{"0":1}}}}"#,
            #"{"model":"m","usage":{"input_tokens":"3"},"answers":{}}"#,
            #"{"usage":{},"answers":{}}"#,
            #"{"model":"m","answers":{}}"#,
        ]
        for body in bad { XCTAssertThrowsError(try SystemOneResult(data: Data(body.utf8)), body) }
    }

    func testErrorMessagesFromEveryServerShape() {
        func m(_ s: String) -> String? { SystemOneClient.message(Data(s.utf8)) }
        XCTAssertEqual(m(#"{"detail":[{"loc":["body","questions","x","choice","criteria"],"msg":"Field required","type":"missing"},{"loc":["body","model"],"msg":"bad","type":"value_error"}]}"#),
                       "questions.x.choice.criteria: Field required; model: bad")
        XCTAssertEqual(m(#"{"detail":{"error_type":"authentication_error","message":"Must supply an API key!"}}"#), "Must supply an API key!")
        XCTAssertEqual(m(#"{"error":{"message":"No auth credentials found","code":401}}"#), "No auth credentials found")
        XCTAssertEqual(m(#"{"error":"not found: GET /x"}"#), "not found: GET /x")
        XCTAssertEqual(m(#"{"detail":"Method Not Allowed"}"#), "Method Not Allowed")
    }

    /// Review 3 N2: Foundation's encoders fold normalization-distinct keys; JSON and Questions refuse instead.
    func testCodableEncodingRefusesNormalizationCollisions() throws {
        let json = JSON.object([.init("\u{E9}", 1), .init("e\u{301}", 2)])
        XCTAssertThrowsError(try JSONEncoder().encode(json)) { XCTAssertTrue($0 is EncodingError) }
        XCTAssertEqual(json.compact, "{\"\u{E9}\":1,\"e\u{301}\":2}", "the wire form keeps both")
        let questions: Questions = ["\u{E9}": .noul("one"), "e\u{301}": .noul("two")]
        XCTAssertThrowsError(try JSONEncoder().encode(questions)) { XCTAssertTrue($0 is EncodingError) }
        XCTAssertThrowsError(try JSONEncoder().encode(JSON.array([json])), "nested objects too")
        XCTAssertNoThrow(try JSONEncoder().encode(JSON.object([.init("a", 1), .init("b", 2)])))
        let ordinary: Questions = ["a": .noul("one")]
        XCTAssertEqual(try JSONDecoder().decode(Questions.self, from: JSONEncoder().encode(ordinary)), ordinary)
    }

    /// Review 3 N4: a present but wrong-typed field throws instead of reading as absent.
    func testAnswerAndJudgementRefuseWrongTypes() throws {
        for body in [#"{"noul":"0.9"}"#, #"{"score":true}"#, #"{"confidence":null}"#, #"{"choice":1}"#,
                     #"{"probabilities":{"a":null}}"#, #"{"probabilities":[0.5]}"#, #"{"calibrated":"no"}"#] {
            XCTAssertThrowsError(try Answer(json: JSON.parse(body)), body)
        }
        XCTAssertEqual(try Answer(json: JSON.parse(#"{"noul":0.9,"confidence":0.9}"#)).noul, 0.9)
        for body in [#"{"answers":[],"model":"m","ms":1}"#, #"{"answers":{},"model":1,"ms":1}"#, #"{"answers":{},"ms":"1"}"#,
                     #"{"error":5}"#, #"{"answers":{"a":{"noul":"x"}}}"#] {
            XCTAssertThrowsError(try Judgement(json: JSON.parse(body)), body)
        }
        let ok = try Judgement(json: JSON.parse(#"{"error":null,"model":null,"answers":{"a":{"noul":0.5}},"ms":2}"#))
        XCTAssertEqual(ok["a"]?.noul, 0.5); XCTAssertNil(ok.model)
    }
}

/// SystemOneClient and the System One API against a real helper with stub models.
final class SystemOneHelperTests: XCTestCase {
    var helper: StubHelper!
    var client: SystemOneClient!

    override func setUp() async throws {
        helper = try StubHelper()
        client = SystemOneClient(verdict: try await Verdict(launch: false, supportDirectory: helper.support))
    }
    override func tearDown() { helper?.stop() }

    func testSystemOneAllTypesAndDiscovery() async throws {
        let base = try await client.resolvedBaseURL()
        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:\(helper.port)")
        // The SystemOneClient docstring's example, verbatim.
        let pr = try await client.systemOne(state: ["title": "Bump lodash to 4.17.21", "files": "package.json, yarn.lock"], questions: [
            "deps": .noul("Does this pull request only change dependencies?"),
            "area": .choice("Which part of the codebase does it touch?", labels: ["frontend", "backend", "build"]),
            "risk": .score("How risky is merging it without review?", levels: ["harmless", "worth a glance", "needs a reviewer"]),
        ])
        let r = pr
        XCTAssertEqual(r.model, "laya-english", "auto routes English text to laya-english")
        XCTAssertEqual(pr.nouls["deps"]?.noul, 0.75)
        XCTAssertEqual(pr.choices["area"]?.choice, "frontend")
        XCTAssertEqual(pr.scores["risk"]?.score, 1)
        XCTAssertEqual(r.scores["risk"]?.legend, [0: "harmless", 1: "worth a glance", 2: "needs a reviewer"])
        XCTAssertEqual(r.raw["answers"]?["deps"], .object([.init("noul", 0.75), .init("type", "noul")]), "a noul answer is {type, noul} only")
        XCTAssertTrue(r.requestID?.hasPrefix("req_") == true)
        XCTAssertNotNil(r.inputTokens)
        let multi = try await client.systemOne(state: "Zażółć gęślą jaźń", questions: ["x": .noul("Is it?")])
        XCTAssertEqual(multi.model, "laya-multilingual")
        let object = try await client.systemOne(state: ["subject": "invoice", "body": "charged twice"], questions: ["x": .noul("Is it?")], model: "von-1.2")
        XCTAssertEqual(object.model, "von-1.2")
    }

    func testValidationErrorsAndModels() async throws {
        do { _ = try await client.systemOne(state: "x", questions: ["q": .noul("?")], model: "jev-latest"); XCTFail("hosted model accepted") }
        catch VerdictError.api(let status, let message) {
            XCTAssertEqual(status, 422); XCTAssertTrue(message.hasPrefix("model: Value error, 'jev-latest' is TypeSafe's hosted model"), message)
        }
        do { _ = try await client.systemOne(state: "x", questions: ["q": .noul("?")], extraBody: [.init("bits", 4.5)]); XCTFail("4.5 bits accepted") }
        catch VerdictError.api(let status, let message) { XCTAssertEqual(status, 422); XCTAssertEqual(message, "bits: Input should be a valid integer") }
        let long = Array(repeating: "w", count: 9000).joined(separator: " ")
        do { _ = try await client.systemOne(state: long, questions: ["q": .noul("?")], model: "laya-english"); XCTFail("over-context state accepted") }
        catch VerdictError.api(let status, let message) { XCTAssertEqual(status, 422); XCTAssertTrue(message.hasPrefix("state: Value error, State needs about"), message) }
        let models = try await client.models()
        XCTAssertEqual(models.first?.name, "auto")
        XCTAssertEqual(Set(models.map(\.name)), ["auto", "laya-english", "laya-multilingual", "laya-typed-decisions", "von-1.2", "von-1.1"])
        XCTAssertTrue(models.allSatisfy { $0.releaseDate.count == 10 && !$0.description.isEmpty })
        // Verdict's catalog view of the same listing: the models plus the hosted reference, human names.
        let catalog = try await client.verdict.models()
        XCTAssertEqual(catalog.map(\.id), ["laya-english", "laya-multilingual", "laya-typed-decisions", "von-1.2", "von-1.1", "jev"])
        XCTAssertEqual(catalog.first?.name, "Laya · English")
    }

    /// Raw requests: an Authorization header changes nothing about the loopback protections, TypeSafe's error body.
    func testLoopbackProtectionsWithAuthorization() async throws {
        let body = #"{"model":"auto","state":"x","questions":{"q":{"type":"noul"}}}"#
        var (code, reply) = try await helper.raw("POST", "/v1/systemone", body: body, headers: ["Content-Type": "application/json", "Authorization": "Bearer sk-anything"])
        XCTAssertEqual(code, 200)
        (code, reply) = try await helper.raw("POST", "/v1/systemone", body: body, headers: ["Content-Type": "application/json", "Authorization": "Bearer x", "Origin": "https://evil.example"])
        XCTAssertEqual(code, 403); XCTAssertEqual((reply["detail"] as? [String: Any])?["error_type"] as? String, "permission_error")
        (code, reply) = try await helper.raw("POST", "/v1/systemone", body: body, headers: ["Content-Type": "text/plain", "Authorization": "Bearer x"])
        XCTAssertEqual(code, 415)
        (code, reply) = try await helper.raw("GET", "/v1/systemone", headers: ["Authorization": "Bearer x"])
        XCTAssertEqual(code, 405)
        (code, reply) = try await helper.raw("POST", "/v1/systemone", body: "{bad", headers: ["Content-Type": "application/json"])
        XCTAssertEqual(code, 422); XCTAssertEqual(((reply["detail"] as? [[String: Any]])?.first)?["type"] as? String, "json_invalid")
    }

    /// Concurrent requests are merged and every caller gets its own answers.
    func testConcurrentRequestsGetTheirOwnAnswers() async throws {
        let client = self.client!
        let results = try await withThrowingTaskGroup(of: (Int, SystemOneResult).self) { group in
            for i in 0..<40 {
                group.addTask {
                    let labels = (0...(i % 4 + 1)).map { "option\($0)" }
                    return (i, try await client.systemOne(state: "item \(i)", questions: ["q\(i)": .choice("Which?", labels: labels)]))
                }
            }
            return try await group.reduce(into: [Int: SystemOneResult]()) { $0[$1.0] = $1.1 }
        }
        for (i, r) in results {
            XCTAssertEqual(r.answers.keys, ["q\(i)"])
            XCTAssertEqual(r.choices["q\(i)"]?.probabilities.count, i % 4 + 2)
        }
    }

    func testBatchExtension() async throws {
        let results = try await client.judge(items: ["please refund me", "hello"], questions: ["refund": .noul("Money back?")])
        XCTAssertEqual(results.map { $0["refund"]?.noul }, [0.75, 0.75])
        let remote = SystemOneClient(baseURL: URL(string: "https://api.typesafe.ai")!, apiKey: "k")
        do { _ = try await remote.judge(items: ["x"], questions: ["q": .noul("?")]); XCTFail() }
        catch VerdictError.invalidRequest(let m) { XCTAssertTrue(m.contains("batch extension")) }
    }
}
