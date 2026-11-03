import Foundation
import Testing
@testable import StatusTrioCore

/// Anti-fabrication gate for evidence fixtures (R7). A fixture whose
/// targetRPM does not equal round(min + p·(max−min)) for its percent is a
/// fabricated number and fails here, printing the offending triple.
@MainActor
struct FanFixtureTests {

    /// Builder-produced fixtures are consistent by construction: the settled
    /// builder computes targets from the daemon's own mapping.
    @Test func settledFixtureTargetsMatchTheDaemonMapping() {
        let (status, config) = FanFixture.settledManual(percent: 45)
        #expect(FanFixture.consistencyIssues(status: status, config: config).isEmpty)
        let fans = status["fans"] as? [[String: Any]] ?? []
        #expect(fans[0]["targetRPM"] as? Double == 3150) // round(1350+0.45×3999)
        #expect(fans[1]["targetRPM"] as? Double == 3402) // round(1458+0.45×4319)
    }

    /// The guard's teeth: a hand-fabricated target (the r5 incident shape —
    /// 2700 @ 45% where the mapping says 3150) is rejected and the offending
    /// triple is printed.
    @Test func guardRejectsFabricatedTargetsAndPrintsTheTriple() {
        var (status, config) = FanFixture.settledManual(percent: 45)
        var fans = status["fans"] as? [[String: Any]] ?? []
        fans[0]["targetRPM"] = 2700.0 // fabricated
        status["fans"] = fans
        let issues = FanFixture.consistencyIssues(status: status, config: config)
        #expect(issues.count == 1)
        #expect(issues[0].contains("2700"))
        #expect(issues[0].contains("3150"))
        #expect(issues[0].contains("45"))
        #expect(issues[0].contains("1350"))
        #expect(issues[0].contains("5349"))
    }

    /// Ramping fixtures are legal (targets mid-convergence) but must render
    /// as pending — the guard's other half: a non-settled manual fixture can
    /// never pose as settled.
    @Test func rampingFixtureAlwaysReadsPending() throws {
        let (status, config) = FanFixture.rampingManual(
            percent: 45, rampTargets: [2700, 2900])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanfixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: status)
            .write(to: dir.appendingPathComponent("status.json"))
        try JSONSerialization.data(withJSONObject: config)
            .write(to: dir.appendingPathComponent("config.json"))
        let monitor = FanMonitor(directory: dir)
        monitor.refresh()
        #expect(monitor.state.manualPercentPending == true)
        #expect(monitor.state.modePending == false)
    }

    /// Settled fixtures render settled (no false pending).
    @Test func settledFixtureReadsSettled() throws {
        let (status, config) = FanFixture.settledManual(percent: 45)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanfixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: status)
            .write(to: dir.appendingPathComponent("status.json"))
        try JSONSerialization.data(withJSONObject: config)
            .write(to: dir.appendingPathComponent("config.json"))
        let monitor = FanMonitor(directory: dir)
        monitor.refresh()
        #expect(monitor.state.manualPercentPending == false)
        #expect(monitor.state.modePending == false)
    }

    /// The validator tolerates override caps and non-zero offsets (both
    /// legitimately deviate from the naive mapping).
    @Test func guardSkipsNonManualModesAndOffsetFixtures() {
        var (status, config) = FanFixture.settledManual(percent: 45)
        var fans = status["fans"] as? [[String: Any]] ?? []
        fans[0]["targetRPM"] = 2700.0
        status["fans"] = fans

        config["mode"] = "curve" // not manual → nothing to validate
        #expect(FanFixture.consistencyIssues(status: status, config: config).isEmpty)

        config["mode"] = "manual"
        config["fanOffsets"] = [10.0, 0.0] // offsets shift targets by design
        #expect(FanFixture.consistencyIssues(status: status, config: config).isEmpty)
    }
}
