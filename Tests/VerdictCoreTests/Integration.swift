import Foundation
import XCTest

/// Tests that spawn processes (the stub helper, the CLI, compilers, codesign) or use the network run locally only:
/// under CI (CI=true, set by GitHub Actions) they skip unless VERDICT_INTEGRATION=1. Run them with
/// `VERDICT_INTEGRATION=1 swift test` before a release (CONTRIBUTING.md).
enum Integration {
    static func require(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let reason = skipReason(environment) { throw XCTSkip(reason) }
    }
    static func skipReason(_ environment: [String: String]) -> String? {
        let ci = (environment["CI"] ?? "").lowercased()
        guard ci == "true" || ci == "1", environment["VERDICT_INTEGRATION"] != "1" else { return nil }
        return "integration test: runs locally, or under CI with VERDICT_INTEGRATION=1"
    }
}

final class IntegrationGateTests: XCTestCase {
    func testSkipsOnlyUnderCIWithoutTheFlag() {
        XCTAssertNil(Integration.skipReason([:]), "locally everything runs")
        XCTAssertNil(Integration.skipReason(["CI": "false"]))
        XCTAssertNotNil(Integration.skipReason(["CI": "true"]))
        XCTAssertNotNil(Integration.skipReason(["CI": "1"]))
        XCTAssertNil(Integration.skipReason(["CI": "true", "VERDICT_INTEGRATION": "1"]))
    }
}
