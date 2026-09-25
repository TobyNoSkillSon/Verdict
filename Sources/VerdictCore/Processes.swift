import Foundation
import Darwin

/// Stray worker detection for the app's start-up sweep. A worker is identified by the executable the process runs,
/// never by a substring of its command line: a shell, editor or agent whose arguments mention the helper's path is
/// not a worker and must survive the sweep.
public enum WorkerProcesses {
    /// The native helper inside any Verdict.app (an earlier instance may have run from another copy of the app).
    public static let helperSuffix = "/Verdict.app/Contents/MacOS/verdict-helper"
    /// The Python worker of earlier releases, run as `python3 <bundle>/Contents/Resources/worker.py`.
    public static let legacyScriptSuffix = "/Verdict.app/Contents/Resources/worker.py"

    /// True when a process running `executable` with `arguments` (argv, argv[0] first) is a Verdict worker.
    public static func isWorker(executable: String, arguments: [String]) -> Bool {
        if executable.hasSuffix(helperSuffix) { return true }
        // The legacy worker: a Python interpreter whose script (first non-option argument) is the bundle's worker.py.
        guard (executable as NSString).lastPathComponent.lowercased().hasPrefix("python") else { return false }
        return arguments.dropFirst().first { !$0.hasPrefix("-") }?.hasSuffix(legacyScriptSuffix) == true
    }

    /// Process ids of this user's Verdict workers, other than `excluding`.
    public static func strays(excluding: pid_t? = nil) -> [pid_t] {
        userProcesses().filter { pid in
            guard pid != excluding, pid != getpid(), let path = executablePath(pid) else { return false }
            // Arguments are only needed (and only read) for Python processes.
            let python = (path as NSString).lastPathComponent.lowercased().hasPrefix("python")
            return isWorker(executable: path, arguments: python ? arguments(pid) ?? [] : [])
        }
    }

    /// Every process owned by the current (real) user.
    public static func userProcesses() -> [pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_RUID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&name, u_int(name.count), &procs, &size, nil, 0) == 0 else { return [] }
        let uid = getuid()
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_eproc.e_pcred.p_ruid == uid && $0.kp_eproc.e_ucred.cr_uid == uid }
            .map { $0.kp_proc.p_pid }
            .filter { $0 > 0 }
    }

    /// The executable file a process runs (proc_pidpath), not what its command line says.
    public static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A process's argv (KERN_PROCARGS2), argv[0] first.
    public static func arguments(_ pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &bytes, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size && bytes[index] != 0 { index += 1 }      // the executable path
        while index < size && bytes[index] == 0 { index += 1 }      // its padding
        var out: [String] = []
        while out.count < argc && index < size {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            out.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return out
    }
}
