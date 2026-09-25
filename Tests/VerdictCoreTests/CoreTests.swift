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

    func testBenchmarksDecodeBothShapes() throws {
        let json = #"""
        {"jev": {"accuracy": 0.695, "ece": 0.246, "ms": 256, "n": null, "note": "published", "sets": {"ag_news": 0.91}, "source": "published"},
         "laya-english": {"default_bits": 16, "precisions": {
            "16": {"accuracy": 0.561, "accuracy_en": 0.561, "accuracy_ml": 0.5, "ece": 0.117, "ms": 4.6, "items_per_s": 580.0, "j_per_1k": 380.0, "memory_mb": 1262,
                   "sets": {"sst2": 0.9}, "n_tasks": 25, "source": "measured", "date": "2026-09-25", "hardware": "Apple M5 Max, macOS 26.6"},
            "8": {"accuracy": 0.557, "ms": 3.4},
            "4": "garbage"}},
         "von-1.2": {"default_bits": 32, "precisions": {"32": {"accuracy": 0.588}}},
         "broken": 7}
        """#
        let map = decodeBenchmarks(Data(json.utf8))
        XCTAssertEqual(Set(map.keys), ["jev", "laya-english", "von-1.2"])
        let laya = try XCTUnwrap(map["laya-english"])
        XCTAssertEqual(laya.default_bits, 16)
        XCTAssertEqual(laya.result(bits: 16)?.memory_mb, 1262)
        XCTAssertEqual(laya.result(bits: 16)?.hardware, "Apple M5 Max, macOS 26.6")
        XCTAssertEqual(laya.result(bits: 8)?.accuracy, 0.557)
        XCTAssertNil(laya.result(bits: 8)?.ece)           // absent field = not measured
        XCTAssertNil(laya.result(bits: 4))                // malformed precision skipped
        XCTAssertEqual(map["von-1.2"]?.defaultResult(nativeBits: 32)?.accuracy, 0.588)
        let jev = try XCTUnwrap(map["jev"])              // legacy flat shape
        XCTAssertNil(jev.default_bits)
        XCTAssertEqual(jev.defaultResult(nativeBits: 16)?.accuracy, 0.695)
        XCTAssertEqual(jev.defaultResult(nativeBits: 16)?.source, "published")
        XCTAssertEqual(jev.defaultResult(nativeBits: 16)?.sets?["ag_news"], 0.91)
        XCTAssertTrue(decodeBenchmarks(Data("not json".utf8)).isEmpty)
    }

    func testPrecisionMapping() {
        XCTAssertEqual(precisionOptions(runtime: "laya"), [16, 8, 4])
        XCTAssertEqual(precisionOptions(runtime: "von"), [32, 16, 8, 4])
        XCTAssertEqual(nativeBits(runtime: "von"), 32)
        XCTAssertEqual(nativeBits(runtime: nil), 16)
        XCTAssertEqual(configBits(effective: 16, native: 16), 0)
        XCTAssertEqual(configBits(effective: 32, native: 32), 0)
        XCTAssertEqual(configBits(effective: 16, native: 32), 16)
        XCTAssertEqual(configBits(effective: 8, native: 16), 8)
        XCTAssertEqual(effectiveBits(config: 0, native: 32), 32)
        XCTAssertEqual(effectiveBits(config: 16, native: 16), 16)
        // Load button: nothing loaded → Load; same precision (0 and 16 are the same for Laya) → Unload; else Reload.
        XCTAssertEqual(loadAction(selected: 8, loaded: nil, native: 16), .load)
        XCTAssertEqual(loadAction(selected: 0, loaded: 0, native: 16), .unload)
        XCTAssertEqual(loadAction(selected: 0, loaded: 16, native: 16), .unload)
        XCTAssertEqual(loadAction(selected: 8, loaded: 0, native: 16), .reload)
        XCTAssertEqual(loadAction(selected: 16, loaded: 0, native: 32), .reload)
        XCTAssertEqual(loadAction(selected: 4, loaded: 4, native: 32), .unload)
    }

    func testDeltaFormatting() {
        XCTAssertEqual(accuracyDelta(0.557, base: 0.561), Delta("\u{2212}0.4 pt", .worse))
        XCTAssertEqual(accuracyDelta(0.563, base: 0.561), Delta("+0.2 pt", .better))
        XCTAssertEqual(accuracyDelta(0.5612, base: 0.561), Delta("\u{00b1}0.0 pt", .neutral))
        XCTAssertNil(accuracyDelta(nil, base: 0.561))
        XCTAssertEqual(eceDelta(0.129, base: 0.117), Delta("+0.012", .worse))
        XCTAssertEqual(eceDelta(0.113, base: 0.117), Delta("\u{2212}0.004", .better))
        XCTAssertEqual(eceDelta(0.1172, base: 0.117), Delta("\u{00b1}0.000", .neutral))
        // Speed is a rate: 4.6 → 3.4 ms is 35% faster; 4.6 → 5.52 ms is 20% slower.
        XCTAssertEqual(speedDelta(3.4, base: 4.6), Delta("35% faster", .better))
        XCTAssertEqual(speedDelta(5.52, base: 4.6), Delta("20% slower", .worse))
        XCTAssertEqual(speedDelta(4.6, base: 14.2), Delta("3.1\u{00d7} faster", .better))
        XCTAssertEqual(speedDelta(4.62, base: 4.6), Delta("same speed", .neutral))
        XCTAssertEqual(speedDelta(4.62, base: 4.6, short: true), Delta("same", .neutral))
        XCTAssertNil(speedDelta(3.4, base: nil))
        XCTAssertEqual(energyDelta(304, base: 380), Delta("20% less energy", .better))
        XCTAssertEqual(energyDelta(304, base: 380, short: true), Delta("20% less", .better))
        XCTAssertEqual(energyDelta(437, base: 380), Delta("15% more energy", .worse))
        XCTAssertEqual(energyDelta(381, base: 380), Delta("same energy", .neutral))
        XCTAssertNil(energyDelta(nil, base: 380))
        XCTAssertEqual(formatMemory(782), "782 MB")
        XCTAssertEqual(formatMemory(1262), "1.26 GB")
        XCTAssertNil(formatMemory(nil))
        XCTAssertEqual(formatMs(4.6), "4.6 ms")
        XCTAssertEqual(formatMs(14.2), "14 ms")
    }
}
