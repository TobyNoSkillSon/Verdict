import CryptoKit
import Foundation
import Security

/// Why an update did not happen, in words for the popup and the CLI.
public struct UpdateError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Where updates come from. Defaults: the GitHub releases API for TobyNoSkillSon/Verdict and the release's download
/// URL, the same files scripts/install-release.sh downloads. Overrides (tests, mirrors), all HTTPS only:
///   VERDICT_UPDATE_API_URL     the "latest release" JSON
///   VERDICT_RELEASE_BASE_URL   the directory holding Verdict-X.Y.Z-arm64.zip and SHA256SUMS (as install-release.sh)
///   VERDICT_UPDATE_CA_CERT     a PEM certificate to trust as the only root (a local test server's CA)
public struct UpdateSource: Sendable {
    public static let defaultAPI = URL(string: "https://api.github.com/repos/TobyNoSkillSon/Verdict/releases/latest")!
    public var apiURL: URL
    public var baseURL: URL?
    public var anchorDER: Data?

    public init(apiURL: URL = defaultAPI, baseURL: URL? = nil, anchorDER: Data? = nil) {
        self.apiURL = apiURL; self.baseURL = baseURL; self.anchorDER = anchorDER
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> UpdateSource {
        var source = UpdateSource()
        if let api = env["VERDICT_UPDATE_API_URL"], !api.isEmpty {
            guard let url = URL(string: api), url.scheme == "https" else { throw UpdateError("VERDICT_UPDATE_API_URL must use HTTPS") }
            source.apiURL = url
        }
        if let base = env["VERDICT_RELEASE_BASE_URL"], !base.isEmpty {
            guard let url = URL(string: base), url.scheme == "https" else { throw UpdateError("Release base URL must use HTTPS") }
            source.baseURL = url
        }
        if let path = env["VERDICT_UPDATE_CA_CERT"], !path.isEmpty {
            guard let pem = try? String(contentsOfFile: path, encoding: .utf8), let der = Self.der(fromPEM: pem) else {
                throw UpdateError("VERDICT_UPDATE_CA_CERT is not a PEM certificate: \(path)")
            }
            source.anchorDER = der
        }
        return source
    }

    /// The download directory for a release: the override, else github.com/…/releases/download/<tag>.
    public func downloadBase(for release: ReleaseInfo) -> URL {
        baseURL ?? URL(string: "https://github.com/TobyNoSkillSon/Verdict/releases/download/v\(release.version)")!
    }

    static func der(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard pem.contains("BEGIN CERTIFICATE"), let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return data
    }
}

/// HTTPS client for the release check and downloads. Redirects must stay on HTTPS (GitHub redirects release assets
/// to its object storage). No cookies, no cache, no credentials; the only headers are Accept and a User-Agent GitHub requires.
public final class UpdateClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let source: UpdateSource
    private var session: URLSession!

    public init(source: UpdateSource) {
        self.source = source
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        config.httpAdditionalHeaders = ["User-Agent": "Verdict-Updater"]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    deinit { session?.finishTasksAndInvalidate() }

    /// The latest published release (GitHub's releases/latest already skips drafts and prereleases).
    public func latest() async throws -> ReleaseInfo {
        var request = URLRequest(url: source.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError("No answer from \(source.apiURL.host ?? "the release server")") }
        switch http.statusCode {
        case 200: break
        case 404: throw UpdateError("No published release found")
        case 403, 429: throw UpdateError("GitHub refused the update check (rate limit); try again later")
        default: throw UpdateError("The release check answered HTTP \(http.statusCode)")
        }
        do { return try ReleaseInfo.parse(data) } catch let error as ReleaseInfo.ParseError { throw UpdateError(error.description) }
    }

    /// The update to offer: the latest release when it is newer than `current`, else nil.
    public func check(current: SemanticVersion) async throws -> ReleaseInfo? {
        try await latest().offer(to: current)
    }

    /// Downloads `name` from the release's directory to `destination`.
    public func download(_ name: String, of release: ReleaseInfo, to destination: URL) async throws {
        let url = source.downloadBase(for: release).appendingPathComponent(name)
        let (temporary, response): (URL, URLResponse)
        do { (temporary, response) = try await session.download(for: URLRequest(url: url)) }
        catch { throw UpdateError("Download of \(name) failed: \(error.localizedDescription)") }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError("Download of \(name) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw UpdateError("Could not reach \(request.url?.host ?? "the release server"): \(error.localizedDescription)") }
    }

    // MARK: URLSessionTaskDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let der = source.anchorDER else {
            completionHandler(.performDefaultHandling, nil); return
        }
        // Test servers: the configured CA is the only root; host name and validity are still checked.
        guard let anchor = SecCertificateCreateWithData(nil, der as CFData) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

/// A downloaded release, checked and unpacked, ready to be installed.
public struct StagedUpdate: Codable, Equatable, Sendable {
    public let version: String
    /// Private working directory (the archive, SHA256SUMS and the unpacked app); removed after installing.
    public let directory: String
    /// The unpacked, verified Verdict.app inside `directory`.
    public let app: String
    public let sha256: String
}

public enum Updater {
    /// Download the release zip and SHA256SUMS, check the SHA-256, unpack, check the bundle and its version, and
    /// verify the code signature: the checks scripts/install-release.sh makes. Leaves nothing behind on failure.
    public static func prepare(_ release: ReleaseInfo, client: UpdateClient, log: (String) -> Void = { _ in }) async throws -> StagedUpdate {
        let directory = try makeWorkDirectory()
        do {
            let zip = directory.appendingPathComponent(release.zipName), sums = directory.appendingPathComponent("SHA256SUMS")
            try await client.download(release.zipName, of: release, to: zip)
            try await client.download("SHA256SUMS", of: release, to: sums)
            log("downloaded \(release.zipName)")
            guard let text = try? String(contentsOf: sums, encoding: .utf8), let expected = expectedSHA256(sums: text, name: release.zipName) else {
                throw UpdateError("Missing or ambiguous SHA-256 for \(release.zipName)")
            }
            let actual = try sha256(of: zip)
            guard actual == expected else { throw UpdateError("SHA-256 mismatch for \(release.zipName)") }
            log("verified SHA-256: \(actual)  \(release.zipName)")
            let unpacked = directory.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else { throw UpdateError("Could not unpack \(release.zipName)") }
            let app = unpacked.appendingPathComponent("Verdict.app")
            try checkBundle(app, version: release.version)
            try verifySignature(app)
            try removeQuarantine(app)
            log("verified signature: Verdict.app \(release.version)")
            return StagedUpdate(version: release.version.description, directory: directory.path, app: app.path, sha256: actual)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func makeWorkDirectory() throws -> URL {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("verdict-update.XXXXXX").utf8CString)
        guard let path = mkdtemp(&template) else { throw UpdateError("Could not create a temporary directory") }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    /// Lowercase hex SHA-256 of a file, read in 1 MB blocks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The app, its helper and Metal library are present, and the bundle says `version`.
    public static func checkBundle(_ app: URL, version: SemanticVersion) throws {
        let fm = FileManager.default
        let helper = app.appendingPathComponent("Contents/MacOS/verdict-helper").path
        let metallib = app.appendingPathComponent("Contents/Resources/mlx.metallib").path
        let metallibSize = ((try? fm.attributesOfItem(atPath: metallib))?[.size] as? NSNumber)?.intValue ?? 0
        guard fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Verdict").path), fm.isExecutableFile(atPath: helper),
              metallibSize > 0 else {
            throw UpdateError("Release archive lacks the native app, helper, or Metal library")
        }
        guard let bundled = bundleVersion(app), SemanticVersion(bundled) == version, bundled == version.description else {
            throw UpdateError("Version in app does not match archive name")
        }
    }

    public static func bundleVersion(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// codesign --verify --deep --strict, as the installers run it.
    public static func verifySignature(_ app: URL) throws {
        let result = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard result.status == 0 else {
            throw UpdateError("Code signature check failed: \(result.output.split(separator: "\n").first.map(String.init) ?? "codesign exit \(result.status)")")
        }
    }

    /// Removes com.apple.quarantine from every file of `root`. URLSession downloads are not quarantined (only apps that
    /// opt in with LSFileQuarantineEnabled are), and the release zip carries no extended attributes; this is a guarantee,
    /// not a repair: an ad-hoc signed app must never be installed quarantined.
    public static func removeQuarantine(_ root: URL) throws {
        var paths = [root.path]
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker { paths.append((root.path as NSString).appendingPathComponent(relative)) }
        }
        for path in paths where getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            guard removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 else { throw UpdateError("Could not clear quarantine on \(path)") }
        }
    }

    /// True when any file of `root` carries com.apple.quarantine.
    public static func isQuarantined(_ root: URL) -> Bool {
        var paths = [root.path]
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker { paths.append((root.path as NSString).appendingPathComponent(relative)) }
        }
        return paths.contains { getxattr($0, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    /// Runs a tool to completion; output is stdout and stderr together.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (127, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
