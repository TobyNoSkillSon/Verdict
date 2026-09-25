// Per-model reporting of which optimized paths are active on this Mac (shown in /status and the app).
import Foundation

/// "fast" when a validated fast tokenizer is active, "library" when the swift-transformers fallback is used.
public protocol TokenizerPathReporting { var tokenizerPath: String { get } }

/// A model with Verdict's optimized inference path (fast tokenizer + windowed attention, each validated at load) and
/// the stock MLX path (swift-transformers tokenizer, stock attention). The helper switches a model to stock when the
/// optimized path fails during inference, for the rest of that model's lifetime.
public protocol InferencePathSwitching: AnyObject {
    /// True while any optimized component (fast tokenizer or windowed attention) serves requests.
    var optimizedPathActive: Bool { get }
    /// `true`: serve requests on the stock path (loads the library tokenizer on first use; throws if it cannot).
    /// `false`: back to the optimized components validated at load. Clears per-question caches either way.
    func useStockPath(_ stock: Bool) throws
}

/// Test-only fault injection: VERDICT_TEST_OPTIMIZED_FAULT=nan (the optimized path returns non-finite logits) or
/// =throw (it throws) on every request it serves. Only tests set it; the app and install scripts never do.
public enum OptimizedPathFault {
    public static let mode = ProcessInfo.processInfo.environment["VERDICT_TEST_OPTIMIZED_FAULT"] ?? ""
    public struct Injected: Error, LocalizedError {
        public var errorDescription: String? { "injected optimized-path failure (VERDICT_TEST_OPTIMIZED_FAULT)" }
    }
    /// Throws when the throw fault applies to a request on the optimized path.
    public static func check(optimized: Bool) throws { if optimized && mode == "throw" { throw Injected() } }
    /// Whether the nan fault poisons this optimized-path output.
    public static func poisons(optimized: Bool) -> Bool { optimized && mode == "nan" }
}
