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
        XCTAssertEqual(energyDelta(1100.2, base: 378.6, short: true), Delta("2.9\u{00d7} more", .worse))
        XCTAssertEqual(energyDelta(760, base: 380), Delta("2.0\u{00d7} more energy", .worse))
        XCTAssertEqual(energyDelta(740, base: 380), Delta("95% more energy", .worse))
    }

    private func bench(_ precisions: [Int: BenchmarkResult]) -> ModelBenchmark { ModelBenchmark(default_bits: nil, precisions: precisions) }
    private func model(_ id: String, runtime: String?, reference: Bool? = nil) -> CatalogModel {
        CatalogModel(id: id, name: id, backbone: "", params: "", repository: reference == true ? "" : "r", subfolder: "", downloadBytes: 0,
                     context: 8192, languages: "", license: "", recommendation: "", recommended: false, reference: reference, runtime: runtime, inputs: nil)
    }

    func testRecommendedPrecisionRule() {
        // Bar = native accuracy (55.4%) - 0.5 pt: 16 and 8 qualify; 16 uses less energy. 4 is 0.6 pt down, excluded
        // despite the lowest energy.
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.554, ms: 8.2, j_per_1k: 422), 8: .init(accuracy: 0.551, ms: 9.9, j_per_1k: 470),
                                             4: .init(accuracy: 0.548, ms: 9.6, j_per_1k: 300)]), native: 16), 16)
        // The bar is the native precision, not the best one: Von 1.1's 4-bit scores 48.5% (noise), native 48.0%;
        // 16-bit's 47.9% is within 0.5 pt of native and uses the least energy.
        let von11 = bench([32: .init(accuracy: 0.480, ms: 15.2, j_per_1k: 1050.2), 16: .init(accuracy: 0.479, ms: 7.43, j_per_1k: 345.5),
                           8: .init(accuracy: 0.480, ms: 8.01, j_per_1k: 387.9), 4: .init(accuracy: 0.485, ms: 7.72, j_per_1k: 379.6)])
        XCTAssertEqual(recommendedBits(von11, native: 32), 16)
        // Exactly 0.5 pt below native counts as within (float error absorbed).
        XCTAssertEqual(recommendedBits(bench([32: .init(accuracy: 0.480, ms: 15, j_per_1k: 1050), 16: .init(accuracy: 0.475, ms: 7.4, j_per_1k: 345)]), native: 32), 16)
        XCTAssertEqual(recommendedBits(bench([32: .init(accuracy: 0.480, ms: 15, j_per_1k: 1050), 16: .init(accuracy: 0.4749, ms: 7.4, j_per_1k: 345)]), native: 32), 32)
        // Energy tie -> lower ms; energy and ms tie -> higher bits.
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.5, ms: 8, j_per_1k: 400), 8: .init(accuracy: 0.5, ms: 7, j_per_1k: 400)]), native: 16), 8)
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.5, ms: 7, j_per_1k: 400), 8: .init(accuracy: 0.5, ms: 7, j_per_1k: 400)]), native: 16), 16)
        // Missing fields: no accuracy = not measured (excluded, even with the lowest energy); missing energy ranks last,
        // then ms decides among those without energy.
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.5, ms: 8, j_per_1k: 400), 8: .init(ms: 3, j_per_1k: 100)]), native: 16), 16)
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.5, ms: 8), 8: .init(accuracy: 0.5, ms: 9, j_per_1k: 900)]), native: 16), 8)
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.5, ms: 8), 8: .init(accuracy: 0.5, ms: 6)]), native: 16), 8)
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.5), 8: .init(accuracy: 0.5)]), native: 16), 16)
        // One measured precision (native): that one. Native unmeasured: no recommendation, even if others are measured.
        XCTAssertEqual(recommendedBits(bench([32: .init(accuracy: 0.588)]), native: 32), 32)
        XCTAssertNil(recommendedBits(bench([16: .init(accuracy: 0.5, j_per_1k: 300)]), native: 32))
        XCTAssertNil(recommendedBits(bench([16: .init(ms: 4)]), native: 16))
        XCTAssertNil(recommendedBits(bench([:]), native: 16))
        XCTAssertNil(recommendedBits(nil, native: 16))
        // Offered options only: a stray 2-bit entry is never recommended.
        XCTAssertEqual(recommendedBits(bench([16: .init(accuracy: 0.5, j_per_1k: 400), 2: .init(accuracy: 0.5, j_per_1k: 10)]), native: 16, options: [16, 8, 4]), 16)
        // Reference (Jev) rows are excluded; the legacy flat shape decodes but is never recommended from.
        let jev = decodeBenchmarks(Data(#"{"jev": {"accuracy": 0.695, "ece": 0.246, "ms": 256, "source": "published"}}"#.utf8))["jev"]
        XCTAssertNil(recommendedBits(for: model("jev", runtime: "hosted", reference: true), benchmark: jev))
        XCTAssertEqual(recommendedBits(for: model("von-1.2", runtime: "von"), benchmark: bench([32: .init(accuracy: 0.527, ms: 15.9, j_per_1k: 1100),
                                                                                          16: .init(accuracy: 0.526, ms: 7.9, j_per_1k: 379)])), 16)
    }

    /// The shipped catalog: the rule, benchmarks.json default_bits and the helper's models.json default_bits agree.
    func testShippedCatalogDefaultsFollowTheRule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let benchmarks = decodeBenchmarks(try Data(contentsOf: root.appendingPathComponent("Resources/benchmarks.json")))
        let catalogData = try Data(contentsOf: root.appendingPathComponent("Resources/models.json"))
        let catalog = try JSONDecoder().decode([CatalogModel].self, from: catalogData)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [[String: Any]])
        var seen: [String: Int] = [:]
        for m in catalog where m.reference != true {
            let rec = try XCTUnwrap(recommendedBits(for: m, benchmark: benchmarks[m.id]), m.id)
            seen[m.id] = rec
            XCTAssertEqual(benchmarks[m.id]?.default_bits, rec, "benchmarks.json default_bits \(m.id)")
            XCTAssertEqual(raw.first { $0["id"] as? String == m.id }?["default_bits"] as? Int, rec, "models.json default_bits \(m.id)")
        }
        XCTAssertEqual(seen, ["laya-english": 16, "laya-multilingual": 16, "laya-typed-decisions": 16, "von-1.2": 16, "von-1.1": 16])
        XCTAssertNil(recommendedBits(for: try XCTUnwrap(catalog.first { $0.id == "jev" }), benchmark: benchmarks["jev"]))
    }

    func testDefaultsAndDeltasAgainstRecommended() throws {
        // No explicit choice -> recommended; explicit 0 -> native; explicit bits -> those.
        XCTAssertEqual(selectedBits(config: nil, recommended: 16, native: 32), 16)
        XCTAssertEqual(selectedBits(config: 0, recommended: 16, native: 32), 32)
        XCTAssertEqual(selectedBits(config: 8, recommended: 16, native: 32), 8)
        XCTAssertEqual(selectedBits(config: nil, recommended: nil, native: 32), 32)
        XCTAssertEqual(configBits(effective: selectedBits(config: nil, recommended: 16, native: 16), native: 16), 0)
        // Von 1.2 with 32 selected, compared with the recommended 16 (shipped figures).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let von = try XCTUnwrap(decodeBenchmarks(try Data(contentsOf: root.appendingPathComponent("Resources/benchmarks.json")))["von-1.2"])
        let base = try XCTUnwrap(von.result(bits: try XCTUnwrap(recommendedBits(von, native: 32, options: [32, 16, 8, 4]))))
        let f32 = try XCTUnwrap(von.result(bits: 32))
        XCTAssertEqual(accuracyDelta(f32.accuracy, base: base.accuracy), Delta("+0.1 pt", .better))
        XCTAssertEqual(speedDelta(f32.ms, base: base.ms, short: true), Delta("2.0\u{00d7} slower", .worse))
        XCTAssertEqual(energyDelta(f32.j_per_1k, base: base.j_per_1k, short: true), Delta("2.9\u{00d7} more", .worse))
    }

    func testEngineLabelAndTooltip() throws {
        let fast = Optimizations(tokenizer: "fast", attention: "windowed", matmul: "neural accelerators", optimized: true)
        let optimized = LoadedModel(device: "mlx", load_s: 1, bits: 16, optimizations: fast, engine: "optimized")
        XCTAssertEqual(engineLabel(optimized, chip: "M5 Max"), "Optimized \u{00b7} M5 Max")
        XCTAssertEqual(engineLabel(optimized, chip: nil), "Optimized")
        let help = engineHelp(optimized, chip: "M5 Max", effectiveBits: 16)
        for part in ["optimized path", "Verdict fast tokenizer", "windowed kernel", "GPU neural accelerators", "Precision: 16-bit"] { XCTAssertTrue(help.contains(part), part) }
        let stock = Optimizations(tokenizer: "library", attention: "stock", matmul: "f32 (by design)", optimized: false)
        let mlx = LoadedModel(device: "mlx", load_s: 1, bits: 0, optimizations: stock, engine: "mlx", engine_reason: "kernel self-test did not pass on this chip")
        XCTAssertEqual(engineLabel(mlx, chip: "M5 Max"), "MLX")
        let why = engineHelp(mlx, chip: "M5 Max", effectiveBits: 32)
        for part in ["Stock MLX path", "Why: kernel self-test did not pass on this chip.", "swift-transformers", "stock MLX attention", "f32", "Precision: 32-bit"] { XCTAssertTrue(why.contains(part), part) }
        // Helpers before the engine field: fast tokenizer + windowed attention = optimized; neural accelerators do not decide it.
        XCTAssertEqual(engineLabel(LoadedModel(device: "mlx", load_s: 1, optimizations: Optimizations(tokenizer: "fast", attention: "windowed", matmul: "standard GPU", optimized: false)), chip: "M4"), "Optimized \u{00b7} M4")
        XCTAssertEqual(engineLabel(LoadedModel(device: "mlx", load_s: 1), chip: "M4"), "MLX")
        // /status decodes the chip and the engine fields.
        let json = #"{"installed":{},"calls":0,"items":0,"started":0,"updated":0,"gpu":{"chip":"M5 Max","architecture":"applegpu_g17s","neural_accelerators":true,"generation":17},"models":{"von-1.2":{"device":"mlx","load_s":0.6,"bits":16,"engine":"mlx","engine_reason":"tokenizer format not recognised"}}}"#
        let status = try JSONDecoder().decode(WorkerStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.gpu?.chip, "M5 Max")
        XCTAssertEqual(status.models["von-1.2"]?.engine_reason, "tokenizer format not recognised")
    }

    /// Review 2 R2.4: a model on the MLX label with the fast tokenizer still active is partly optimized, not stock.
    func testEngineTooltipForAPartlyOptimizedModel() {
        let partial = LoadedModel(device: "mlx", load_s: 1, bits: 16,
                                  optimizations: Optimizations(tokenizer: "fast", attention: "stock", matmul: "neural accelerators", optimized: false),
                                  engine: "mlx", engine_reason: "windowed attention disabled (VERDICT_LAYA_WINDOW=0)")
        XCTAssertEqual(engineLabel(partial, chip: "M5 Max"), "MLX")
        let help = engineHelp(partial, chip: "M5 Max", effectiveBits: 16)
        XCTAssertFalse(help.contains("without Verdict's optimizations"), help)
        XCTAssertFalse(help.contains("Stock MLX path"), help)
        for part in ["Partly optimized", "active: Verdict fast tokenizer", "stock: MLX attention", "Why: windowed attention disabled (VERDICT_LAYA_WINDOW=0).",
                     "Tokenizer: Verdict fast tokenizer", "Attention: stock MLX attention"] { XCTAssertTrue(help.contains(part), part + " in " + help) }
        // Library tokenizer with windowed attention that passed its self-test: also partial.
        let other = LoadedModel(device: "mlx", load_s: 1, bits: 16,
                                optimizations: Optimizations(tokenizer: "library", attention: "windowed", optimized: false),
                                engine: "mlx", engine_reason: "tokenizer format not recognised")
        let otherHelp = engineHelp(other, chip: nil, effectiveBits: 16)
        for part in ["Partly optimized", "active: windowed attention", "stock: library tokenizer"] { XCTAssertTrue(otherHelp.contains(part), part + " in " + otherHelp) }
        // A runtime switch to stock (both off) is still described as the stock path.
        let switched = LoadedModel(device: "mlx", load_s: 1, bits: 16,
                                   optimizations: Optimizations(tokenizer: "library", attention: "stock", optimized: false),
                                   engine: "mlx", engine_reason: "the optimized path failed during inference (boom); switched to the stock MLX path")
        XCTAssertTrue(engineHelp(switched, chip: nil, effectiveBits: 16).hasPrefix("Stock MLX path: the same model without Verdict's optimizations"))
        // The one-line summary no longer invents a cause for a stock component.
        let summary = Optimizations(tokenizer: "fast", attention: "stock", optimized: false).summary
        XCTAssertFalse(summary.contains("self-test did not pass"), summary)
        XCTAssertTrue(summary.contains("fast tokenizer"), summary)
    }

    func testReloadStateWithRecommendedDefault() {
        // Von, nothing explicit: selection is the recommended 16 (config bits 16). The helper loaded its default 16.
        let selected = configBits(effective: selectedBits(config: nil, recommended: 16, native: 32), native: 32)
        XCTAssertEqual(selected, 16)
        XCTAssertEqual(loadAction(selected: selected, loaded: 16, native: 32), .unload)
        XCTAssertEqual(loadAction(selected: selected, loaded: 0, native: 32), .reload)     // loaded f32, 16 selected
        XCTAssertEqual(loadAction(selected: 0, loaded: 16, native: 32), .reload)           // user picked 32 on a 16 load
        XCTAssertEqual(loadAction(selected: selected, loaded: nil, native: 32), .load)
        // Laya: recommended 16 is native, stored as 0; the helper reports 0 or 16, both the same precision.
        let laya = configBits(effective: selectedBits(config: nil, recommended: 16, native: 16), native: 16)
        XCTAssertEqual(loadAction(selected: laya, loaded: 0, native: 16), .unload)
        XCTAssertEqual(loadAction(selected: laya, loaded: 16, native: 16), .unload)
        XCTAssertEqual(loadAction(selected: 8, loaded: 0, native: 16), .reload)
    }

    // MARK: Keep Hot per class, Memory, launch set

    func testKeepHotAndMemoryConfigDefaultsAndLegacy() throws {
        func decode(_ json: String) throws -> Configuration { try JSONDecoder().decode(Configuration.self, from: Data(json.utf8)) }
        let fresh = try decode(#"{"executable":"/x","hotModels":["laya-english"],"launchAtLogin":false}"#)
        XCTAssertEqual("\(fresh.manualIdle) \(fresh.onDemandIdle) \(fresh.swapAllowed)", "0 15 false")
        // A config from before per-class Keep Hot: its single window becomes the manual one if the menu offers it.
        XCTAssertEqual(try decode(#"{"executable":"/x","hotModels":[],"launchAtLogin":false,"idleMinutes":60}"#).manualIdle, 60)
        XCTAssertEqual(try decode(#"{"executable":"/x","hotModels":[],"launchAtLogin":false,"idleMinutes":240}"#).manualIdle, 0)
        let current = try decode(#"{"executable":"/x","hotModels":[],"launchAtLogin":false,"idleMinutes":60,"manualIdleMinutes":30,"onDemandIdleMinutes":0,"allowSwap":true}"#)
        XCTAssertEqual("\(current.manualIdle) \(current.onDemandIdle) \(current.swapAllowed)", "30 0 true")
        // Round trip keeps the new fields.
        let again = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(again, current)
    }

    /// A fresh install loads nothing at launch: the launch set starts empty and grows only by manual loads.
    func testFreshConfigurationPreloadsNothing() throws {
        let fresh = Configuration(executable: "/Applications/Verdict.app/Contents/MacOS/verdict-helper")
        XCTAssertEqual(fresh.hotModels, [])
        XCTAssertEqual(fresh.helperEnvironment["VERDICT_PRELOAD"], "")
        let saved = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(saved.hotModels, [])
        // An existing config keeps its launch set.
        let existing = try JSONDecoder().decode(Configuration.self, from: Data(#"{"executable":"/x","hotModels":["laya-multilingual","laya-english"],"launchAtLogin":false}"#.utf8))
        XCTAssertEqual(existing.helperEnvironment["VERDICT_PRELOAD"], "laya-multilingual,laya-english")
    }

    func testHelperEnvironmentAndSettings() {
        var config = Configuration(executable: "/x", hotModels: ["laya-english", "von-1.2"])
        config.precision = ["von-1.2": 0]
        XCTAssertEqual(config.helperEnvironment, ["VERDICT_PRELOAD": "laya-english,von-1.2", "VERDICT_IDLE_MINUTES": "0",
                                                  "VERDICT_MANUAL_IDLE_MINUTES": "0", "VERDICT_ON_DEMAND_IDLE_MINUTES": "15",
                                                  "VERDICT_ALLOW_SWAP": "0", "VERDICT_PRECISION": #"{"von-1.2":0}"#])
        config = applying(.keepHot(.manual, minutes: 60), to: config)
        config = applying(.keepHot(.onDemand, minutes: 5), to: config)
        config = applying(.memory(allowSwap: true), to: config)
        XCTAssertEqual([config.manualIdleMinutes, config.idleMinutes, config.onDemandIdleMinutes], [60, 60, 5]); XCTAssertEqual(config.allowSwap, true)
        XCTAssertEqual(config.helperSettings, ["manual_idle_minutes": "60", "on_demand_idle_minutes": "5", "allow_swap": "true"])
        XCTAssertEqual(config.helperEnvironment["VERDICT_IDLE_MINUTES"], "60")      // older helpers read the manual value
        XCTAssertEqual(config.helperEnvironment["VERDICT_ALLOW_SWAP"], "1")
    }

    func testKeepHotMenu() {
        let menu = keepHotMenu(Configuration(executable: "/x"))
        let titles: [String] = menu.map {
            switch $0 {
            case .header(let t, _): return "# " + t
            case .choice(let t, let checked, _, _): return t + (checked ? " ✓" : "")
            case .caption(let t): return "(" + t + ")"
            case .separator: return "—"
            }
        }
        XCTAssertEqual(titles, ["# Manually loaded", "Always ✓", "15 min idle", "30 min idle", "60 min idle", "—",
                                "# Loaded on demand", "5 min idle", "15 min idle ✓", "30 min idle", "60 min idle", "Always", "—",
                                "(Unloaded models reload on the next request)"])
        guard case .choice(_, _, let action, let help) = menu[11] else { return XCTFail("on-demand Always") }
        XCTAssertEqual(action, .keepHot(.onDemand, minutes: 0))
        XCTAssertEqual(help, keepHotAlwaysHelp)
        // Tooltips: each group header says what puts a model in it; Always says what can still unload it.
        XCTAssertEqual(menu[0], .header("Manually loaded", help: manualLoadHelp))
        XCTAssertEqual(menu[6], .header("Loaded on demand", help: onDemandLoadHelp))
        let helped = menu.compactMap { entry -> String? in if case .choice(let t, _, _, let h?) = entry { return t + ": " + h }; return nil }
        XCTAssertEqual(helped, ["Always: " + keepHotAlwaysHelp, "Always: " + keepHotAlwaysHelp])
        var custom = Configuration(executable: "/x"); custom.manualIdleMinutes = 30; custom.onDemandIdleMinutes = 0
        let checked = keepHotMenu(custom).compactMap { entry -> MenuAction? in
            if case .choice(_, true, let action, _) = entry { return action }; return nil
        }
        XCTAssertEqual(checked, [.keepHot(.manual, minutes: 30), .keepHot(.onDemand, minutes: 0)])
    }

    func testMemoryMenu() {
        var status = WorkerStatus(); status.memory = ["available_mb": 86_940]
        status.evictions = [Eviction(model: "von-1.2", reason: "idle: unused for 15 min (loaded on demand)", at: 1),
                            Eviction(model: "laya-multilingual", reason: "memory: made room for von-1.2 at 16-bit", at: 2)]
        let automatic = memoryMenu(Configuration(executable: "/x"), status: status)
        XCTAssertEqual(automatic, [.choice(title: "Fit in free memory", checked: true, action: .memory(allowSwap: false), help: fitInFreeMemoryHelp),
                                   .choice(title: "Allow swap (slower)", checked: false, action: .memory(allowSwap: true), help: allowSwapHelp),
                                   .separator, .caption("~86.9 GB free now"), .caption("Unloaded laya-multilingual to make room")])
        XCTAssertEqual(fitInFreeMemoryHelp, "Loads a model only if it fits in memory that is free right now; otherwise unloads idle models (least recently used, on-demand first) or refuses with the reason. Never pushes the Mac into swap.")
        XCTAssertEqual(allowSwapHelp, "Loads even when memory is short; macOS moves data to disk and everything, including other apps, can slow down.")
        var swap = Configuration(executable: "/x"); swap.allowSwap = true
        // The swap item is a toggle: checked, choosing it again turns it off.
        XCTAssertEqual(memoryMenu(swap, status: nil), [.choice(title: "Fit in free memory", checked: false, action: .memory(allowSwap: false), help: fitInFreeMemoryHelp),
                                                       .choice(title: "Allow swap (slower)", checked: true, action: .memory(allowSwap: false), help: allowSwapHelp)])
    }

    func testLaunchSetFollowsManualLoadsOnly() throws {
        let json = #"{"installed":{},"calls":0,"items":0,"started":0,"updated":0,"models":{"laya-english":{"device":"mlx","load_s":0.6,"residency":"manual","last_used":5,"context":8192},"von-1.2":{"device":"mlx","load_s":1,"residency":"on_demand","last_used":9,"context":8192},"von-1.1":{"device":"mlx","load_s":1,"residency":"manual","context":2048}},"evictions":[{"model":"laya-multilingual","residency":"on_demand","reason":"memory: made room","at":3}],"refused":null,"manual_idle_minutes":0,"on_demand_idle_minutes":15,"allow_swap":false}"#
        let status = try JSONDecoder().decode(WorkerStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.models["von-1.1"]?.context, 2048)
        XCTAssertEqual(status.models["von-1.2"]?.residency, "on_demand")
        XCTAssertEqual(status.evictions?.first?.model, "laya-multilingual")
        XCTAssertEqual(launchSet(["laya-english"], adding: status), ["laya-english", "von-1.1"])     // on-demand von-1.2 stays out
        XCTAssertNil(launchSet(["von-1.1", "laya-english"], adding: status))
        // An evicted or idle-unloaded manual model stays in the launch set: nothing is removed from status alone.
        XCTAssertNil(launchSet(["laya-english", "von-1.1", "laya-typed-decisions"], adding: status))
    }

    func testFooterNotice() {
        var status = WorkerStatus()
        status.refused = Refusal(model: "von-1.2", message: "von-1.2 at 16-bit needs ~2.0 GB", at: 1000)
        XCTAssertEqual(footerNotice(lastError: nil, status: status, now: 1100), "von-1.2 at 16-bit needs ~2.0 GB")
        XCTAssertNil(footerNotice(lastError: nil, status: status, now: 1700))                // older than 10 minutes
        XCTAssertEqual(footerNotice(lastError: "Worker is not ready.", status: status, now: 1100), "Worker is not ready.")
        status.error = "boom"
        XCTAssertEqual(footerNotice(lastError: nil, status: status, now: 1100), "boom")
        XCTAssertEqual(formatContext(2048), "2k")
        XCTAssertEqual(formatContext(8192), "8k")
        XCTAssertEqual(formatContext(32000), "32k")   // Jev: OpenRouter lists 32,000
    }
}
