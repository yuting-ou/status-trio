import Foundation
import Testing
@testable import StatusTrioCore

@MainActor
struct FanMonitorTests {
    private func makeFixture(
        status: [String: Any],
        config: [String: Any]
    ) throws -> (FanMonitor, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanmonitor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: status)
            .write(to: dir.appendingPathComponent("status.json"))
        try JSONSerialization.data(withJSONObject: config)
            .write(to: dir.appendingPathComponent("config.json"))
        return (FanMonitor(directory: dir), dir)
    }

    private func freshStatus() -> [String: Any] {
        [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "mode": "curve",
            "controlFault": false,
            "powerWatts": 12.5,
            "sensors": ["cpuDie": 63.4, "gpuDie": 51.2, "ssd": 38.9],
            "fans": [
                ["id": 1, "actualRPM": 3006.0, "targetRPM": 3100.0,
                 "minRPM": 1458.0, "maxRPM": 5777.0],
                ["id": 0, "actualRPM": 2745.0, "targetRPM": 2800.0,
                 "minRPM": 1350.0, "maxRPM": 5349.0],
            ],
        ]
    }

    private func readConfig(_ dir: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("config.json"))
        ) as? [String: Any] ?? [:]
    }

    // MARK: - Reading

    @Test func parsesTempsRpmsRangesPowerAndMode() throws {
        let (monitor, _) = try makeFixture(
            status: freshStatus(),
            config: ["mode": "curve", "preset": "quiet", "curve": FanCurveChoice.quiet.points]
        )
        monitor.refresh()
        #expect(monitor.state.daemonAlive)
        #expect(monitor.state.cpuTemp == 63.4)
        #expect(monitor.state.gpuTemp == 51.2)
        #expect(monitor.state.ssdTemp == 38.9)
        #expect(monitor.state.powerWatts == 12.5)
        // Fans publish in id order regardless of payload order.
        #expect(monitor.state.fanRPMs == [2745.0, 3006.0])
        #expect(monitor.state.fanTargetRPMs == [2800.0, 3100.0])
        // RPM bounds come from status.json, never hardcoded.
        #expect(monitor.state.fanRanges.count == 2)
        #expect(monitor.state.fanRanges[0].min == 1350.0)
        #expect(monitor.state.fanRanges[0].max == 5349.0)
        #expect(monitor.state.fanRanges[1].min == 1458.0)
        #expect(monitor.state.fanRanges[1].max == 5777.0)
        #expect(monitor.state.modeSelection == .curve)
        #expect(monitor.state.curveSelection == .quiet)
        #expect(monitor.state.curveIsCustom == false)
    }

    @Test func staleStatusMarksDaemonOffline() throws {
        var status = freshStatus()
        status["timestamp"] = ISO8601DateFormatter()
            .string(from: Date().addingTimeInterval(-120))
        let (monitor, _) = try makeFixture(status: status, config: ["mode": "auto"])
        monitor.refresh()
        #expect(!monitor.state.daemonAlive)
    }

    @Test func zeroTempIsTreatedAsFaultMarkerNotAirTemperature() throws {
        var status = freshStatus()
        status["sensors"] = ["cpuDie": 0.0, "gpuDie": 41.0]
        let (monitor, _) = try makeFixture(status: status, config: [:])
        monitor.refresh()
        #expect(monitor.state.cpuTemp == nil)
        #expect(monitor.state.gpuTemp == 41.0)
    }

    // MARK: - Selection mapping

    @Test func modeSelectionMapsAllFourDaemonModes() throws {
        for (raw, expected) in [("auto", FanModeChoice.auto), ("curve", .curve),
                                ("ai", .ai), ("manual", .manual)] {
            let (monitor, _) = try makeFixture(status: freshStatus(), config: ["mode": raw])
            monitor.refresh()
            #expect(monitor.state.modeSelection == expected, "mode=\(raw)")
        }
    }

    @Test func curveSelectionRequiresPointsToMatchThePresetLabel() throws {
        // Label quiet + factory quiet points → selected.
        let (m1, _) = try makeFixture(
            status: freshStatus(),
            config: ["mode": "curve", "preset": "quiet", "curve": FanCurveChoice.quiet.points]
        )
        m1.refresh()
        #expect(m1.state.curveSelection == .quiet)
        #expect(!m1.state.curveIsCustom)

        // Label quiet + AI-personalized points (the daemon/optimizer case):
        // showing "quiet" selected would be a lie → custom.
        var tuned = FanCurveChoice.quiet.points
        tuned[0]["temp"] = 59
        let (m2, _) = try makeFixture(
            status: freshStatus(),
            config: ["mode": "curve", "preset": "quiet", "curve": tuned]
        )
        m2.refresh()
        #expect(m2.state.curveSelection == nil)
        #expect(m2.state.curveIsCustom)
    }

    @Test func aiTargetSelectionCoversGearsAndRejectsNonStandardValues() throws {
        for (value, expected) in [(72.0, FanAITargetChoice.performance),
                                  (76.0, .balanced), (80.0, .quiet)] {
            let (monitor, _) = try makeFixture(
                status: freshStatus(), config: ["mode": "ai", "aiTargetTemp": value])
            monitor.refresh()
            #expect(monitor.state.aiTargetSelection == expected, "target=\(value)")
        }
        let (custom, _) = try makeFixture(
            status: freshStatus(), config: ["mode": "ai", "aiTargetTemp": 73.5])
        custom.refresh()
        #expect(custom.state.aiTargetSelection == nil)
        #expect(custom.state.aiTargetRaw == 73.5)
    }

    // MARK: - Writers

    @Test func setModeWritesOnlyTheModeKeyAndPreservesParams() throws {
        let (monitor, dir) = try makeFixture(
            status: freshStatus(),
            config: ["mode": "curve", "aiTargetTemp": 72, "manualPercent": 45,
                     "quietHours": true, "preset": "quiet",
                     "curve": FanCurveChoice.quiet.points]
        )
        #expect(monitor.setMode(.ai))
        let written = try readConfig(dir)
        #expect(written["mode"] as? String == "ai")
        // Params survive a pure mode switch (same as FanCtl's own setMode).
        #expect(written["aiTargetTemp"] as? Int == 72)
        #expect(written["manualPercent"] as? Int == 45)
        #expect(written["quietHours"] as? Bool == true)
        #expect((written["curve"] as? [[String: Any]])?.count == 5)
        #expect(monitor.state.modeSelection == .ai)
    }

    @Test func setCurvePresetWritesModePresetAndFactoryPoints() throws {
        let (monitor, dir) = try makeFixture(
            status: freshStatus(), config: ["mode": "ai", "aiTargetTemp": 72])
        #expect(monitor.setCurvePreset(.balanced))
        let written = try readConfig(dir)
        #expect(written["mode"] as? String == "curve")
        #expect(written["preset"] as? String == "balanced")
        let curve = try #require(written["curve"] as? [[String: Any]])
        #expect(curve.count == 5)
        #expect(curve.first?["temp"] as? Double == 52)
        #expect(curve.last?["percent"] as? Double == 100)
        #expect(monitor.state.modeSelection == .curve)
        #expect(monitor.state.curveSelection == .balanced)
    }

    @Test func setAITargetWritesModeAndTargetTemperature() throws {
        let (monitor, dir) = try makeFixture(
            status: freshStatus(), config: ["mode": "curve"])
        #expect(monitor.setAITarget(.quiet))
        let written = try readConfig(dir)
        // The daemon contract: config.json keys "mode"="ai" + "aiTargetTemp"=80.
        #expect(written["mode"] as? String == "ai")
        #expect(written["aiTargetTemp"] as? Int == 80)
        #expect(monitor.state.modeSelection == .ai)
        #expect(monitor.state.aiTargetSelection == .quiet)
    }

    @Test func setManualPercentClampsIntoTheDaemonDomain() async throws {
        let (monitor, dir) = try makeFixture(
            status: freshStatus(), config: ["mode": "curve", "manualPercent": 30])
        // UI can never emit these (slider is bounded), but the writer clamps
        // defense-in-depth so no caller value is ever rewritten by the daemon.
        monitor.setManualPercent(150)
        var written = try await waitForManualWrite(dir, percent: 100)
        #expect(written["mode"] as? String == "manual")
        #expect(written["manualPercent"] as? Int == 100)

        monitor.setManualPercent(-20)
        written = try await waitForManualWrite(dir, percent: 0)
        #expect(written["manualPercent"] as? Int == 0)

        monitor.setManualPercent(45)
        written = try await waitForManualWrite(dir, percent: 45)
        #expect(written["manualPercent"] as? Int == 45)
        #expect(monitor.state.manualPercent == 45)
    }

    /// Poll until the debounced manual write lands (or the deadline passes and
    /// the assertions fail on the final state). Load-independent: a fixed
    /// sleep flakes under a busy main actor.
    private func waitForManualWrite(_ dir: URL, percent: Int) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        var config = try readConfig(dir)
        while Date() < deadline {
            if config["manualPercent"] as? Int == percent { return config }
            try await Task.sleep(for: .milliseconds(50))
            config = try readConfig(dir)
        }
        return config
    }

    @Test func manualSliderDomainMatchesTheDaemonClampRange() {
        // The daemon clamps manualPercent to [0,100] (FanConfig.sanitized);
        // the slider must span exactly that domain — wider would show values
        // the daemon rewrites (a lie), narrower would hide reachable gears.
        // FanStatusView's Slider reads this same constant.
        #expect(FanMonitor.manualPercentRange.lowerBound == 0)
        #expect(FanMonitor.manualPercentRange.upperBound == 100)
    }

    @Test func writersRefuseWhenExistingConfigIsUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanmonitor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: freshStatus())
            .write(to: dir.appendingPathComponent("status.json"))
        let monitor = FanMonitor(directory: dir)
        // No config.json at all → refuse instead of writing a partial document
        // the daemon would reject (manualPercent/curve are required keys).
        #expect(monitor.setMode(.auto) == false)
        #expect(monitor.setAITarget(.balanced) == false)
        #expect(monitor.setCurvePreset(.quiet) == false)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path))

        try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(monitor.setMode(.manual) == false)
        let stillCorrupt = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        #expect(stillCorrupt == Data("not json".utf8))
    }

    @Test func foreignKeysRoundTripThroughEveryWriter() throws {
        let config: [String: Any] = [
            "mode": "curve", "aiTargetTemp": 72, "manualPercent": 30,
            "quietHours": true, "nightCurve": [["temp": 59.0, "percent": 0.0]],
            "envCompensation": true, "palmCompensation": true,
        ]
        let (monitor, dir) = try makeFixture(status: freshStatus(), config: config)
        #expect(monitor.setMode(.ai))
        #expect(monitor.setAITarget(.performance))
        let written = try readConfig(dir)
        #expect(written["quietHours"] as? Bool == true)
        #expect((written["nightCurve"] as? [[String: Any]])?.count == 1)
        #expect(written["envCompensation"] as? Bool == true)
        #expect(written["palmCompensation"] as? Bool == true)
        #expect(written["manualPercent"] as? Int == 30)
    }

}
