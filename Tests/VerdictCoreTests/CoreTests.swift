import XCTest
@testable import VerdictCore

final class CoreTests: XCTestCase {
    func testPhases() {
        XCTAssertEqual(phase(for: nil, processRunning: false), .stopped)
        XCTAssertEqual(phase(for: nil, processRunning: true), .starting)
        var s = WorkerStatus(); s.port = 1
        XCTAssertEqual(phase(for: s, processRunning: true), .ready(hot: 0))
        s.loading = "laya-english"
        XCTAssertEqual(phase(for: s, processRunning: true), .loading("laya-english"))
        s.downloading = true
        XCTAssertEqual(phase(for: s, processRunning: true), .downloading("laya-english"))
        s.downloading = false
        s.loading = nil; s.error = "boom"
        XCTAssertEqual(phase(for: s, processRunning: true), .failed("boom"))
        s.models["laya-english"] = LoadedModel(device: "mps", load_s: 3)
        XCTAssertEqual(phase(for: s, processRunning: true), .ready(hot: 1))
    }
    func testSummary() {
        var s = WorkerStatus(); s.port = 1; s.items = 1204
        XCTAssertEqual(summaryLine(.ready(hot: 2), status: s), "Verdict: 2 models hot · 1,204 judgements")
        XCTAssertEqual(summaryLine(.ready(hot: 0), status: s), "Verdict: ready, no model hot")
        XCTAssertEqual(summaryLine(.stopped, status: nil), "Verdict: stopped")
        s.last_ms = 23.4
        XCTAssertEqual(latencyLine(s), "Last judgement 23 ms")
        s.memory = ["mlx_active_mb": 1486]
        XCTAssertEqual(latencyLine(s), "Last judgement 23 ms · 1.5 GB in memory")
    }
    func testConfigValidation() {
        XCTAssertThrowsError(try Configuration(executable: "").validate())
        XCTAssertNoThrow(try Configuration(executable: "/Applications/Verdict.app/Contents/MacOS/verdict-helper").validate())
    }

    func testOptimizationStatusDecodesAndSummarises() throws {
        let json = #"{"installed":{},"calls":0,"items":0,"started":0,"updated":0,"models":{"laya-english":{"device":"mlx","load_s":0.6,"bits":0,"optimizations":{"tokenizer":"fast","attention":"windowed","matmul":"standard GPU","optimized":false}}}}"#
        let status = try JSONDecoder().decode(WorkerStatus.self, from: Data(json.utf8))
        let o = try XCTUnwrap(status.models["laya-english"]?.optimizations)
        XCTAssertFalse(o.optimized)
        XCTAssertTrue(o.summary.hasPrefix("Standard on this Mac"))
        XCTAssertTrue(o.summary.contains("fast tokenizer, windowed attention"))
        XCTAssertTrue(o.summary.contains("standard GPU matmul"))
        let old = #"{"installed":{},"calls":0,"items":0,"started":0,"updated":0,"models":{"laya-english":{"device":"mlx","load_s":0.6}}}"#
        XCTAssertNil(try JSONDecoder().decode(WorkerStatus.self, from: Data(old.utf8)).models["laya-english"]?.optimizations)
    }
}
