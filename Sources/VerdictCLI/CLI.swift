import Foundation
import VerdictKit
import VerdictUpdate

let usage = """
verdict: judge many items with the same typed questions, locally, in milliseconds.

    verdict judge --questions q.json [--field KEY] [--sort NAME] [--min X] [--top N] [--model ID] [--bits N] [--json] < items.jsonl
        one line per item:  #index  name=value(conf) …  | first 60 characters of the item
        --field KEY judges that key of each JSONL object (default: the whole line); --sort orders by a question's
        score / probability, highest first; --json prints every probability; --bits N refuses to run unless the
        model runs at N bits (verdict load ID --bits N switches it, for every client)
    verdict status                         port, loaded models, memory, Keep Hot, recent unloads
    verdict models [--all] [--json]        catalog at each model's selected precision (--all: every precision)
    verdict info MODEL [--json]            one model: every precision, task breakdown, source, links
    verdict load ID [--bits N] [--manual]  load on demand; --manual loads like the menu (launch set); --bits N reloads at N bits
    verdict unload ID
    verdict url                            the local base URL for TypeSafe SDKs (base_url / baseURL / TYPESAFE_BASE_URL)
    verdict skill [--install DIR]          print the agent skill (named triage), or write DIR/triage/SKILL.md
    verdict diagnose [--load] [--json]     chip, macOS, versions, each loaded model's engine, fallbacks and timing on 20
                                           built-in items, and a prefilled GitHub bug-report URL (no user data;
                                           --load loads laya-english first if needed; never starts the app)
    verdict licenses                       Verdict's NOTICE and the licences of the code it bundles
    verdict update [--check]               install the latest release from GitHub: SHA-256 and signature checked,
                                           settings and models kept, this version restored if the new one does not
                                           start; refused while a model is loading. --check only reports
    verdict --version                      this command's version (the app's)

q.json: {"name": {"type": "noul"|"choice"|"score", "instructions": "…", "criteria": …}, …}
Talks to the Verdict app over its local HTTP API (docs/API.md: compatible with the System One API (TypeSafe Jev),
plus /v1/judge for batches); starts the app if it is not running.
"""

struct CLIError: Error { let message: String; init(_ message: String) { self.message = message } }

/// The `verdict` command. `write`/`warn` are stdout/stderr; tests capture them.
struct CLI {
    var verdict = Verdict(unchecked: true)
    /// The System One client over `verdict` (judge is its batch extension).
    var client: SystemOneClient { SystemOneClient(verdict: verdict) }
    var write: (String) -> Void = { print($0) }
    var warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    var readInput: () -> String = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }

    func run(_ argv: [String]) async -> Int32 {
        guard var command = argv.first, !["-h", "--help", "help"].contains(command) else { write(usage); return 0 }
        if command == "--licenses" { command = "licenses" }
        if command == "--version" || command == "version" {
            guard let info = versionInfo() else { warn("error: Info.plist not found"); return 1 }
            write("verdict \(info.version) (build \(info.build))"); return 0
        }
        do {
            try await dispatch(command, Array(argv.dropFirst()))
            return 0
        } catch let error as CLIError {
            warn("error: \(error.message)"); return 1
        } catch {
            warn("error: \(error.localizedDescription)"); return 1
        }
    }

    /// Options with values (`--bits 8`) and flags (`--json`); anything else is positional.
    struct Arguments {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        init(_ args: [String], values valueOptions: Set<String>, flags flagOptions: Set<String>) throws {
            var i = 0
            while i < args.count {
                let a = args[i]
                if valueOptions.contains(a) {
                    guard i + 1 < args.count else { throw CLIError("\(a) needs a value") }
                    values[a] = args[i + 1]; i += 2
                } else if flagOptions.contains(a) {
                    flags.insert(a); i += 1
                } else if a.hasPrefix("--") {
                    throw CLIError("unknown option \(a)")
                } else {
                    positional.append(a); i += 1
                }
            }
        }
        func int(_ name: String) throws -> Int? {
            guard let raw = values[name] else { return nil }
            guard let v = Int(raw) else { throw CLIError("\(name) takes a whole number, not '\(raw)'") }
            return v
        }
        func double(_ name: String) throws -> Double? {
            guard let raw = values[name] else { return nil }
            guard let v = Double(raw) else { throw CLIError("\(name) takes a number, not '\(raw)'") }
            return v
        }
    }

    func dispatch(_ command: String, _ rest: [String]) async throws {
        switch command {
        case "status":
            _ = try Arguments(rest, values: [], flags: [])
            Format.status(try await verdict.status()).forEach(write)
        case "models":
            let args = try Arguments(rest, values: [], flags: ["--all", "--json"])
            if args.flags.contains("--json") { write(try await modelsJSON().pretty); return }
            let models = try await verdict.models()
            (args.flags.contains("--all") ? Format.allPrecisions(models) : Format.table(models)).forEach(write)
        case "info":
            let args = try Arguments(rest, values: [], flags: ["--json"])
            guard let id = args.positional.first else { throw CLIError("verdict info <model>") }
            if args.flags.contains("--json") {
                guard let model = try await modelsJSON().array?.first(where: { $0["id"]?.string == id }) else { throw unknownModel(id) }
                write(model.pretty); return
            }
            guard let model = try await verdict.models().first(where: { $0.id == id }) else { throw unknownModel(id) }
            Format.info(model).forEach(write)
        case "load", "unload":
            let args = try Arguments(rest, values: command == "load" ? ["--bits"] : [], flags: command == "load" ? ["--manual"] : [])
            guard let id = args.positional.first else { throw CLIError("verdict \(command) ID") }
            let loaded = command == "load"
                ? try await verdict.load(id, bits: try args.int("--bits"), manual: args.flags.contains("--manual"))
                : try await verdict.unload(id)
            write(Format.list(loaded))
        case "judge": try await judge(rest)
        case "url":
            _ = try Arguments(rest, values: [], flags: [])
            write(try await client.resolvedBaseURL().absoluteString)
        case "skill":
            let args = try Arguments(rest, values: ["--install"], flags: [])
            guard let text = skillText() else { throw CLIError("SKILL.md not found; is Verdict installed?") }
            if let dir = args.values["--install"] {
                let dest = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("triage/SKILL.md")
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: dest)
                write("wrote \(dest.path)")
            } else {
                write(text)
            }
        case "diagnose":
            let args = try Arguments(rest, values: [], flags: ["--load", "--json"])
            if let extra = args.positional.first { throw CLIError("unexpected argument \(extra)") }
            let cli = versionInfo()?.version
            let diagnosis = try await Diagnose.collect(verdict, cliVersion: cli, load: args.flags.contains("--load"))
            let url = Diagnose.issueURL(diagnosis)
            if args.flags.contains("--json") { write(Diagnose.json(diagnosis, issueURL: url).pretty); return }
            Diagnose.text(diagnosis).forEach(write)
            write("")
            write("report it (opens a prefilled GitHub bug report; add what you saw): \(url)")
        case "licenses":
            _ = try Arguments(rest, values: [], flags: [])
            guard let notice = resourceText("NOTICE", source: "NOTICE"),
                  let thirdParty = resourceText("THIRD_PARTY_NOTICES.txt", source: "Resources/THIRD_PARTY_NOTICES.txt") else {
                throw CLIError("NOTICE not found; is Verdict installed?")
            }
            write(notice); write(thirdParty)
        case "update":
            let args = try Arguments(rest, values: ["--finish"], flags: ["--check"])
            if let extra = args.positional.first { throw CLIError("unexpected argument \(extra)") }
            if let plan = args.values["--finish"] { try await finishUpdate(plan); return }
            try await update(checkOnly: args.flags.contains("--check"))
        default: throw CLIError("unknown command \(command)")
        }
    }

    private func unknownModel(_ id: String) -> CLIError { CLIError("unknown model '\(id)'; see verdict models") }

    /// The catalog entries of /v1/models (local models, then hosted references) as the API ordered them, for --json.
    private func modelsJSON() async throws -> JSON {
        .array(Verdict.catalog(try JSON.parse(try await verdict.request("GET", "/v1/models"))))
    }

    func judge(_ rest: [String]) async throws {
        let args = try Arguments(rest, values: ["--questions", "--model", "--sort", "--top", "--min", "--field", "--bits"], flags: ["--json"])
        if let extra = args.positional.first { throw CLIError("unexpected argument \(extra)") }
        guard let path = args.values["--questions"] else { throw CLIError("--questions FILE is required") }
        let top = try args.int("--top"), minimum = try args.double("--min"), bits = try args.int("--bits")
        let field = args.values["--field"], sort = args.values["--sort"]
        let questionsJSON: JSON
        do { questionsJSON = try JSON.parse(try Data(contentsOf: URL(fileURLWithPath: path))) }
        catch let error as JSON.ParseError { throw CLIError("\(path): \(error.message)") }
        catch { throw CLIError("cannot read \(path): \(error.localizedDescription)") }
        let questions = try Questions(json: questionsJSON)
        if let sort, questions[sort] == nil { throw CLIError("--sort \(sort) is not a question in \(path) (\(questions.ids.joined(separator: ", ")))") }
        for warning in questions.lint() { warn("warning: \(warning)") }
        var items: [JSON] = []
        for (n, line) in readInput().split(whereSeparator: \.isNewline).enumerated() where !line.allSatisfy(\.isWhitespace) {
            do { items.append(try JSON.parse(String(line))) } catch let error as JSON.ParseError { throw CLIError("input line \(n + 1): \(error.message)") }
        }
        guard !items.isEmpty else { return }
        let states = items.map { item in field.map { item.members != nil ? (item[$0] ?? .null) : item } ?? item }
        let results = try await client.judgeJSON(states, questions: questionsJSON, model: args.values["--model"] ?? "auto", bits: bits)
        var rows = Array(zip(items.indices, zip(items, results)))
        if let sort {
            rows = rows.enumerated().sorted { a, b in
                let x = Format.sortKey(a.element.1.1, sort), y = Format.sortKey(b.element.1.1, sort)
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
            if let minimum { rows = rows.filter { Format.sortKey($0.1.1, sort) >= minimum } }
        }
        if let top, top > 0 { rows = Array(rows.prefix(top)) }
        for (index, (item, result)) in rows {
            if args.flags.contains("--json") {
                write(JSON.object([.init("index", JSON(index)), .init("item", item)] + (result.members ?? [])).spaced)
            } else {
                write(Format.line(index: index, item: item, result: result, field: field, order: questions.ids))
            }
        }
    }

    /// `verdict update`: the same check, download, verification and install as the app's Update menu item.
    func update(checkOnly: Bool) async throws {
        guard let text = versionInfo()?.version, let current = SemanticVersion(text) else { throw CLIError("cannot tell this Verdict's version") }
        let client = UpdateClient(source: try UpdateSource.fromEnvironment())
        guard let release = try await client.check(current: current) else { write("Verdict \(current) is up to date"); return }
        write("Verdict \(release.version) is available (installed: \(current))")
        for line in release.shortNotes().split(separator: "\n") { write("  \(line)") }
        if checkOnly { write("install it with: verdict update"); return }
        guard let app = updateTarget() else { throw CLIError("run the verdict command inside Verdict.app (or set VERDICT_APP) to update it") }
        let support = Verdict.defaultSupportDirectory
        if !Installer.appProcesses(at: app).isEmpty, let loading = Installer.loadingModel(support: support) {
            throw CLIError("Verdict is loading \(loading). Try again in a moment; installation left unchanged")
        }
        let staged = try await Updater.prepare(release, client: client, log: write)
        let plan = InstallPlan(staged: staged, destination: app.path, from: current.description, supportDirectory: support.path, writeResult: false)
        try await Installer(plan: plan, log: write).run()
        write("ready: Verdict \(release.version)")
    }

    /// `verdict update --finish PLAN`: the app's hand-off. It runs detached after the app quits; progress goes to
    /// update.log and the outcome to update-result.json, which the relaunched app reports.
    func finishUpdate(_ path: String) async throws {
        let planData: Data
        do { planData = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw CLIError("cannot read \(path)") }
        let plan = try JSONDecoder().decode(InstallPlan.self, from: planData)
        try? FileManager.default.removeItem(atPath: path)
        let logURL = URL(fileURLWithPath: plan.supportDirectory).appendingPathComponent("update.log")
        let log: (String) -> Void = { line in
            let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
            if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(Data(stamped.utf8)); try? handle.close() }
            else { try? Data(stamped.utf8).write(to: logURL) }
        }
        log("update \(plan.from) -> \(plan.staged.version) at \(plan.destination)")
        do { try await Installer(plan: plan, log: log).run(); log("updated to \(plan.staged.version)") }
        catch { log("failed: \(error.localizedDescription)"); throw error }
    }

    /// The Verdict.app to update: the one this command ships in, else VERDICT_APP.
    func updateTarget() -> URL? {
        if let app = Verdict.containingApp { return app }
        if let path = ProcessInfo.processInfo.environment["VERDICT_APP"], !path.isEmpty,
           FileManager.default.fileExists(atPath: path + "/Contents/Info.plist") { return URL(fileURLWithPath: path) }
        return nil
    }

    /// This command's version: the app it ships in, else the source checkout it was built from.
    func versionInfo() -> (version: String, build: String)? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for url in [Verdict.containingApp?.appendingPathComponent("Contents/Info.plist"), root.appendingPathComponent("Resources/Info.plist")] {
            if let url, let info = NSDictionary(contentsOf: url), let version = info["CFBundleShortVersionString"] as? String {
                return (version, info["CFBundleVersion"] as? String ?? "?")
            }
        }
        return nil
    }

    /// The agent skill: from the app this command ships in, the installed app, or a source checkout.
    func skillText() -> String? { resourceText("SKILL.md", source: "Resources/SKILL.md") }

    /// A file in the app's Contents/Resources (this command's app, then the installed one), else in a source checkout.
    func resourceText(_ name: String, source: String) -> String? {
        var candidates = verdict.appCandidates.map { $0.appendingPathComponent("Contents/Resources/\(name)") }
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(source))   // Sources/VerdictCLI/CLI.swift -> root
        for url in candidates { if let text = try? String(contentsOf: url, encoding: .utf8) { return text } }
        return nil
    }
}
