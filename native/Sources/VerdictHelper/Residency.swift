import Foundation
import Darwin

/// Why a model is loaded. Manual: loaded from the app's menu (Load/Reload, `/load` with `"manual": true`) or at launch
/// (the launch set). On demand: loaded because a request needed it (`/judge` auto-load, `/load` without the flag).
/// Each class has its own Keep Hot idle window; memory eviction takes on-demand models before manual ones.
enum Residency: String {
    case manual
    case onDemand = "on_demand"
}

/// A load that would push macOS into swap in Automatic memory mode. HTTP 507; the message is shown verbatim by the
/// client, the CLI and the app's models table.
struct MemoryRefusal: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Best-effort estimate of the memory macOS can hand out right now without swapping, in MB (1e6 bytes, like memory_mb
/// in benchmarks.json). It is a load-time check, not a guarantee: other processes and later inference allocations are
/// not bounded by it.
///
///     pages_mb  = (free_count − speculative_count      truly free pages
///                  + external_page_count              file-backed pages: dropped or written back, never swapped
///                                                     (includes the speculative read-ahead pages)
///                  + purgeable_count) × page size     volatile purgeable pages: discarded, never swapped
///                 (host_statistics64 HOST_VM_INFO64; the same split as Activity Monitor's free + cached files)
///     level_mb  = kern.memorystatus_level / 100 × RAM                              (the kernel's own pressure gauge)
///     margin_mb = max(1 GB, 10% of RAM)
///     raw       = min(pages_mb, level_mb) − margin_mb   (negative when already short)
///     available = max(0, raw)
///
/// The three page populations are disjoint: purgeable objects are anonymous, so a purgeable page is never
/// file-backed, and speculative pages are counted once (as file-backed). inactive_count is not used: it overlaps both
/// purgeable and file-backed pages, and its anonymous remainder is compressed or swapped, not freed. The memorystatus
/// minimum makes a Mac already under pressure refuse loads. Test hooks, re-read on every check:
/// VERDICT_TEST_MEMORY_FILE = JSON {"available_mb": N} → raw = N − the estimates of the models loaded now (so
/// evictions free what they are expected to); VERDICT_TEST_VM_STATS = JSON with the counters above, page_size and
/// memorystatus_level in place of the kernel's.
struct MemoryProbe {
    static let headroomMB = 512.0
    static var totalMB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1e6 }
    static var marginMB: Double { max(1000, totalMB * 0.10) }
    let testFile: URL?
    let vmStatsFile: URL?

    init(environment: [String: String]) {
        testFile = environment["VERDICT_TEST_MEMORY_FILE"].map { URL(fileURLWithPath: $0) }
        vmStatsFile = environment["VERDICT_TEST_VM_STATS"].map { URL(fileURLWithPath: $0) }
    }

    /// `available` above: never negative.
    func availableMB(loadedMB: Double) -> Double { max(0, rawAvailableMB(loadedMB: loadedMB)) }

    /// `raw` above: negative when memory is already short.
    /// `loadedMB`: Σ load estimates of the models loaded now (used by the test probe only).
    func rawAvailableMB(loadedMB: Double) -> Double {
        if let testFile {
            let base = (Self.json(testFile)?["available_mb"] as? NSNumber)?.doubleValue ?? 0
            return base - loadedMB
        }
        let counters = vmStatsFile.map { Self.json($0) ?? [:] }
        return Swift.min(pagesMB(counters), levelPercent(counters) / 100 * Self.totalMB) - Self.marginMB
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Reclaimable-without-swap pages in MB from the kernel's counters (formula above; disjoint populations).
    static func reclaimableMB(free: Double, speculative: Double, external: Double, purgeable: Double, pageSize: Double) -> Double {
        (Swift.max(0, free - speculative) + external + purgeable) * pageSize / 1e6
    }

    private static let host = mach_host_self()
    private func pagesMB(_ counters: [String: Any]?) -> Double {
        if let counters {
            func value(_ key: String) -> Double { (counters[key] as? NSNumber)?.doubleValue ?? 0 }
            return Self.reclaimableMB(free: value("free_count"), speculative: value("speculative_count"), external: value("external_page_count"),
                                      purgeable: value("purgeable_count"), pageSize: value("page_size"))
        }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(Self.host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Self.reclaimableMB(free: Double(info.free_count), speculative: Double(info.speculative_count), external: Double(info.external_page_count),
                                  purgeable: Double(info.purgeable_count), pageSize: Double(vm_kernel_page_size))
    }
    private func levelPercent(_ counters: [String: Any]?) -> Double {
        if let level = counters?["memorystatus_level"] as? NSNumber { return level.doubleValue }
        return Self.levelPercent()
    }
    static func levelPercent() -> Double {
        var value: Int32 = 100; var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0 ? Double(value) : 100
    }
}

/// Load-size estimate in MB, without the activation headroom: the measured memory_mb for this model and precision
/// (phys_footprint after load + warm-up, so it includes process overhead and is conservative for a second model);
/// else the weights on disk (or the catalog download size) scaled to the precision, plus a fixed runtime overhead.
func memoryEstimateMB(_ spec: ModelSpec, bits: Int, measured: [String: [Int: Double]], diskBytes: Int?) -> Double {
    let effective = spec.effectiveBits(bits)
    if let mb = measured[spec.id]?[effective] { return mb }
    let disk = Double(diskBytes ?? (spec.raw["downloadBytes"] as? NSNumber)?.intValue ?? 0) / 1e6
    // Quantized weights carry group scales/biases and unquantized embeddings: 8/4-bit get 25% on top.
    let factor = Double(effective) / Double(spec.nativeBits) * (effective <= 8 ? 1.25 : 1)
    return disk * factor + 768
}

/// "1.5" for 1,520 MB.
func gigabytes(_ mb: Double) -> String { String(format: "%.1f", Swift.max(0, mb) / 1000) }

/// The refusal text: need, what is free, and the ways out that exist for this request. `loaded`: models that could be
/// unloaded (never one the request itself needs). `together`: other models this request needs that are loaded now;
/// unloading them cannot help (the request loads them again), so the advice is to split the request instead.
func refusalMessage(_ spec: ModelSpec, bits: Int, needMB: Double, freeMB: Double, loaded: [String], together: [String] = []) -> String {
    let effective = spec.effectiveBits(bits)
    var fixes: [String] = []
    var context = ""
    if !together.isEmpty {
        let names = together + [spec.id]
        context = " This request needs " + names.dropLast().joined(separator: ", ") + " and " + names.last! + " loaded together."
        fixes.append("send one request per model")
    }
    if !loaded.isEmpty { fixes.append("unload " + loaded.joined(separator: " or ")) }
    if let lower = spec.precisionOptions.first(where: { $0 < effective }) { fixes.append("pick \(lower)-bit") }
    fixes.append("allow swap in Verdict → Memory")
    var advice = fixes.count == 1 ? fixes[0] : fixes.dropLast().joined(separator: ", ") + (fixes.count > 2 ? ", or " : " or ") + fixes.last!
    advice = advice.prefix(1).uppercased() + advice.dropFirst()
    return "\(spec.id) at \(effective)-bit needs ~\(gigabytes(needMB)) GB; ~\(gigabytes(freeMB)) GB free without swapping.\(context) \(advice)."
}
