import Foundation
import CryptoKit

struct ModelSpec {
    let id: String
    let repository: String
    let revision: String?
    let runtime: String
    let context: Int
    let inputs: [String]
    let raw: [String: Any]
}

struct ServiceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class Catalog {
    let entries: [ModelSpec]
    let raw: [[String: Any]]
    private let fm = FileManager.default
    private let cache: URL

    init() throws {
        let env = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executableDirectory = executable.deletingLastPathComponent()
        let candidates = [
            env["VERDICT_CATALOG"].map { URL(fileURLWithPath: $0) },
            executableDirectory.appendingPathComponent("models.json"),
            executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources/models.json"),
            root.appendingPathComponent("Resources/models.json")
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]] else {
            throw ServiceError("models.json not found")
        }
        raw = obj
        entries = obj.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return ModelSpec(id: id, repository: m["repository"] as? String ?? "", revision: m["revision"] as? String, runtime: m["runtime"] as? String ?? "laya", context: m["context"] as? Int ?? 8192, inputs: m["inputs"] as? [String] ?? [], raw: m)
        }
        cache = URL(fileURLWithPath: env["HF_HUB_CACHE"] ?? ((env["HF_HOME"] ?? ((env["HOME"] ?? NSHomeDirectory()) + "/.cache/huggingface")) + "/hub"), isDirectory: true)
    }
    func spec(_ id: String) throws -> ModelSpec {
        guard let spec = entries.first(where: { $0.id == id && !$0.repository.isEmpty }) else {
            throw ServiceError("Unknown or hosted-only model '\(id)'; loadable: " + entries.filter { !$0.repository.isEmpty }.map(\.id).joined(separator: ", "))
        }
        return spec
    }
    private func base(_ spec: ModelSpec) -> URL {
        cache.appendingPathComponent("models--" + spec.repository.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }
    private func required(_ spec: ModelSpec) -> [String] {
        spec.runtime == "von" ? ["option_marker.pt", "config.json", "tokenizer.json", "tokenizer_config.json", "marker_calibration.json"] : ["model.safetensors", "manifest.json", "mlx_config.json"]
    }
    func cached(_ spec: ModelSpec) -> URL? {
        let base = base(spec)
        let ref = spec.revision ?? (try? String(contentsOf: base.appendingPathComponent("refs/main"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshots = base.appendingPathComponent("snapshots")
        let names = spec.revision.map { [$0] } ?? ([ref].compactMap { $0 } + ((try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []))
        let dirs = names.map { snapshots.appendingPathComponent($0) }
        return dirs.first { dir in
            let files = spec.runtime == "von" ? required(spec) : ["model.safetensors"]
            return files.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }
    func installed() -> [String: Any] {
        var out: [String: Any] = [:]
        for spec in entries where !spec.repository.isEmpty {
            guard let dir = cached(spec) else { continue }
            var size = 0
            for file in required(spec) {
                let path = dir.appendingPathComponent(file).resolvingSymlinksInPath()
                size += (try? fm.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
            }
            out[spec.id] = ["bytes": size]
        }
        return out
    }
    func delete(_ spec: ModelSpec) {
        guard let dir = cached(spec) else { return }
        let root = base(spec)
        let ownedBlobs = root.appendingPathComponent("blobs").standardizedFileURL.path + "/"
        let snapshots = root.appendingPathComponent("snapshots")
        for file in required(spec) {
            let link = dir.appendingPathComponent(file)
            let blob = link.resolvingSymlinksInPath()
            try? fm.removeItem(at: link)
            // A manually linked local checkpoint belongs to its owner, not to
            // this cache. Different pinned Von revisions may also share blobs.
            if blob.standardizedFileURL.path.hasPrefix(ownedBlobs),
               let siblings = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil),
               !siblings.contains(where: { sibling in
                   required(spec).contains { name in
                       let candidate = sibling.appendingPathComponent(name)
                       return fm.fileExists(atPath: candidate.path) && candidate.resolvingSymlinksInPath() == blob
                   }
               }) {
                try? fm.removeItem(at: blob)
            }
        }
        if spec.runtime == "von" { try? fm.removeItem(at: dir.appendingPathComponent("von-encoder.safetensors")) }
    }
    func snapshot(_ spec: ModelSpec) throws -> URL {
        if let cached = cached(spec), required(spec).allSatisfy({ fm.fileExists(atPath: cached.appendingPathComponent($0).path) }) { return cached }
        let url = URL(string: "https://huggingface.co/api/models/\(spec.repository)/revision/\(spec.revision ?? "main")")!
        let data = try downloadData(url)
        guard let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = meta["sha"] as? String, let siblings = meta["siblings"] as? [[String: Any]], spec.revision == nil || sha == spec.revision else { throw ServiceError("Invalid Hugging Face manifest/revision for \(spec.id)") }
        let root = base(spec), dest = root.appendingPathComponent("snapshots/\(sha)")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let selected: Set<String> = spec.runtime == "von" ? Set(required(spec)) : ["model.safetensors", "manifest.json", "mlx_config.json", "rl_agent_config.json", "validation.json", "encoder/config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"]
        // HF's tree metadata supplies the same content-addressed blob names as huggingface_hub.
        var metadata: [String: [String: Any]] = [:]
        let folders = Set([""] + selected.compactMap { $0.contains("/") ? String($0.split(separator: "/").first!) : nil })
        for folder in folders {
            let path = "https://huggingface.co/api/models/\(spec.repository)/tree/\(sha)" + (folder.isEmpty ? "" : "/\(folder)") + "?expand=true"
            guard let tree = try JSONSerialization.jsonObject(with: downloadData(URL(string: path)!)) as? [[String: Any]] else { throw ServiceError("Invalid Hugging Face tree for \(spec.id)") }
            for entry in tree { if let file = entry["path"] as? String { metadata[file] = entry } }
        }
        // Download only repository files; never run repository code. Existing cache files are reused.
        for sibling in siblings {
            guard let file = sibling["rfilename"] as? String, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { continue }
            guard selected.contains(file) else { continue }
            let link = dest.appendingPathComponent(file)
            if fm.fileExists(atPath: link.path) { continue }
            guard let detail = metadata[file], let blobName = ((detail["lfs"] as? [String: Any])?["oid"] as? String) ?? detail["oid"] as? String else { throw ServiceError("Missing content hash for \(file)") }
            let blob = root.appendingPathComponent("blobs/\(blobName)")
            try fm.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: blob.path) {
                // A partial Hugging Face/Xet cache can leave a symlink whose
                // target was evicted. fileExists follows it and says false,
                // but moveItem would fail because the directory entry exists.
                if (try? fm.destinationOfSymbolicLink(atPath: blob.path)) != nil {
                    try fm.removeItem(at: blob)
                }
                let fileURL = URL(string: "https://huggingface.co/\(spec.repository)/resolve/\(sha)/" + file.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"))!
                let temporary = try downloadFile(fileURL)
                if let hash = (detail["lfs"] as? [String: Any])?["oid"] as? String {
                    let handle = try FileHandle(forReadingFrom: temporary)
                    defer { try? handle.close() }
                    var digest = SHA256()
                    while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
                    guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw ServiceError("SHA-256 mismatch: \(file)") }
                }
                do { try fm.moveItem(at: temporary, to: blob) }
                catch {
                    // Another process may have completed this content-addressed
                    // blob during our download. Use its complete file, not a
                    // second write; keep other errors visible.
                    guard fm.fileExists(atPath: blob.path) else { throw error }
                    try? fm.removeItem(at: temporary)
                }
            }
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: blob)
        }
        let refs = root.appendingPathComponent("refs")
        try fm.createDirectory(at: refs, withIntermediateDirectories: true)
        if spec.revision == nil { try sha.write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8) }
        guard required(spec).allSatisfy({ fm.fileExists(atPath: dest.appendingPathComponent($0).path) }) else { throw ServiceError("Incomplete snapshot for \(spec.id)") }
        return dest
    }
    private func downloadData(_ url: URL) throws -> Data {
        let (data, response) = try syncDownload(url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { throw ServiceError("Download failed: \(url)") }
        return data
    }
    private func downloadFile(_ url: URL) throws -> URL {
        let tmp = cache.appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        URLSession.shared.downloadTask(with: url) { location, response, error in
            if let error { failure = error }
            else if (response as? HTTPURLResponse)?.statusCode != 200 { failure = ServiceError("Download failed: \(url)") }
            else if let location {
                do { try self.fm.moveItem(at: location, to: tmp) } catch { failure = error }
            } else { failure = ServiceError("Download failed: \(url)") }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure { throw failure }
        return tmp
    }
    private func syncDownload(_ url: URL) throws -> (Data?, URLResponse?) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: url) { data, response, error in result = (data, response, error); semaphore.signal() }.resume()
        semaphore.wait()
        if let error = result.2 { throw error }
        return (result.0, result.1)
    }
}
