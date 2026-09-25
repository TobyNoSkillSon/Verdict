import XCTest
@testable import VerdictCore

/// The app's start-up sweep must stop stray workers and nothing else. It used to be `pgrep -f <helper path>`, which
/// also matched (and killed) any process whose command line merely contained the path — an agent's shell, an editor.
final class ProcessesTests: XCTestCase {
    func testMatchesExecutableNotCommandLine() {
        let helper = "/Applications/Verdict.app/Contents/MacOS/verdict-helper"
        XCTAssertTrue(WorkerProcesses.isWorker(executable: helper, arguments: [helper]))
        XCTAssertTrue(WorkerProcesses.isWorker(executable: "/tmp/x/Verdict.app/Contents/MacOS/verdict-helper", arguments: []))
        XCTAssertFalse(WorkerProcesses.isWorker(executable: "/bin/zsh", arguments: ["zsh", "-c", "ls \(helper)"]))
        XCTAssertFalse(WorkerProcesses.isWorker(executable: "/bin/cat", arguments: ["cat", helper]))
        XCTAssertFalse(WorkerProcesses.isWorker(executable: helper + ".bak", arguments: []))
        let script = "/Applications/Verdict.app/Contents/Resources/worker.py"
        XCTAssertTrue(WorkerProcesses.isWorker(executable: "/usr/bin/python3", arguments: ["python3", "-u", script]))
        XCTAssertTrue(WorkerProcesses.isWorker(executable: "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
                                               arguments: ["python3", script]))
        XCTAssertFalse(WorkerProcesses.isWorker(executable: "/usr/bin/python3", arguments: ["python3", "-c", "print('\(script)')"]))
        XCTAssertFalse(WorkerProcesses.isWorker(executable: "/usr/bin/vim", arguments: ["vim", script]))
    }

    /// Live: a sleeper installed as <tmp>/Verdict.app/Contents/MacOS/verdict-helper is found; a shell
    /// whose arguments contain that same path (and the sleep it runs) are not.
    func testSweepLeavesShellWithHelperPathInArgumentsAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdict-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let macos = root.appendingPathComponent("Verdict.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let fake = macos.appendingPathComponent("verdict-helper")
        // A freshly compiled sleeper (Apple's own binaries refuse to launch from another path).
        let cc = Process(); cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-x", "c", "-", "-o", fake.path]
        let source = Pipe(); cc.standardInput = source
        try cc.run()
        source.fileHandleForWriting.write(Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8))
        try source.fileHandleForWriting.close()
        cc.waitUntilExit()
        try XCTSkipUnless(cc.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: fake.path), "no C compiler for the fake helper")

        let worker = Process(); worker.executableURL = fake
        let shell = Process(); shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30; : \(fake.path)"]
        try worker.run(); try shell.run()
        defer { worker.terminate(); shell.terminate() }
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(WorkerProcesses.arguments(shell.processIdentifier)?.last, "sleep 30; : \(fake.path)")
        XCTAssertEqual(WorkerProcesses.executablePath(worker.processIdentifier).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       fake.resolvingSymlinksInPath().path)
        let strays = WorkerProcesses.strays()
        XCTAssertTrue(strays.contains(worker.processIdentifier), "the fake helper was not found")
        XCTAssertFalse(strays.contains(shell.processIdentifier), "a shell with the helper path in its arguments was matched")
        XCTAssertFalse(strays.contains(worker.processIdentifier) && strays.contains(getpid()))
        XCTAssertFalse(WorkerProcesses.strays(excluding: worker.processIdentifier).contains(worker.processIdentifier))
        XCTAssertTrue(WorkerProcesses.userProcesses().contains(getpid()))
    }
}
