// Per-model reporting of which optimized paths are active on this Mac (shown in /status and the app).

/// "fast" when a validated fast tokenizer is active, "library" when the swift-transformers fallback is used.
public protocol TokenizerPathReporting { var tokenizerPath: String { get } }
