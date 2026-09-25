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

/// Memory macOS can hand out right now without swapping, in MB (1e6 bytes, like memory_mb in benchmarks.json).
///
///     pages_mb  = (free_count + inactive_count + purgeable_count) × page size       (host_statistics64 HOST_VM_INFO64;
///                 free_count already contains the speculative pages, vm_stat prints them separately)
///     level_mb  = kern.memorystatus_level / 100 × RAM                              (the kernel's own pressure gauge)
///     margin_mb = max(1 GB, 10% of RAM)
///     available = max(0, min(pages_mb, level_mb) − margin_mb)
///
/// Inactive pages are reclaimable without swap only partly (anonymous ones get compressed first), which the margin
/// absorbs; the memorystatus minimum makes a Mac already under pressure refuse loads. Test hook:
/// VERDICT_TEST_MEMORY_FILE = JSON {"available_mb": N} → available = N − the estimates of the models loaded now (so
/// evictions free what they are expected to); the file is re-read on every check.
struct MemoryProbe {
    static let headroomMB = 512.0
    static var totalMB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1e6 }
    static var marginMB: Double { max(1000, totalMB * 0.10) }
    let testFile: URL?

    init(environment: [String: String]) {
        testFile = environment["VERDICT_TEST_MEMORY_FILE"].map { URL(fileURLWithPath: $0) }
    }

    /// `loadedMB`: Σ load estimates of the models loaded now (used by the test probe only).
    func availableMB(loadedMB: Double) -> Double {
        if let testFile {
            let object = (try? Data(contentsOf: testFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let base = (object?["available_mb"] as? NSNumber)?.doubleValue ?? 0
            return max(0, base - loadedMB)
        }
        return max(0, Swift.min(Self.pagesMB(), Self.levelMB()) - Self.marginMB)
    }

    private static let host = mach_host_self()
    static func pagesMB() -> Double {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = Double(info.free_count) + Double(info.inactive_count) + Double(info.purgeable_count)
        return pages * Double(vm_kernel_page_size) / 1e6
    }
    static func levelPercent() -> Double {
        var value: Int32 = 100; var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0 ? Double(value) : 100
    }
    static func levelMB() -> Double { levelPercent() / 100 * totalMB }
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

/// The refusal text: need, what is free, and the ways out that exist for this request.
func refusalMessage(_ spec: ModelSpec, bits: Int, needMB: Double, freeMB: Double, loaded: [String]) -> String {
    let effective = spec.effectiveBits(bits)
    var fixes: [String] = []
    if !loaded.isEmpty { fixes.append("unload " + loaded.joined(separator: " or ")) }
    if let lower = spec.precisionOptions.first(where: { $0 < effective }) { fixes.append("pick \(lower)-bit") }
    fixes.append("allow swap in Verdict → Memory")
    var advice = fixes.count == 1 ? fixes[0] : fixes.dropLast().joined(separator: ", ") + (fixes.count > 2 ? ", or " : " or ") + fixes.last!
    advice = advice.prefix(1).uppercased() + advice.dropFirst()
    return "\(spec.id) at \(effective)-bit needs ~\(gigabytes(needMB)) GB; ~\(gigabytes(freeMB)) GB free without swapping. \(advice)."
}
