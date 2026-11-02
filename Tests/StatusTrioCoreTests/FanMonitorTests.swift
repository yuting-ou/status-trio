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
            "sensors": ["cpuDie": 63.4, "gpuDie": 51.2, "ssd": 38.9],
            "fans": [
                ["id": 1, "actualRPM": 3006.0],
                ["id": 0, "actualRPM": 2745.0],
            ],
        ]
    }

    @Test func parsesTempsRpmsAndMode() throws {
        let (monitor, _) = try makeFixture(
            status: freshStatus(),
            config: ["mode": "curve", "preset": "quiet"]
        )
        monitor.refresh()
        #expect(monitor.state.daemonAlive)
        #expect(monitor.state.cpuTemp == 63.4)
        #expect(monitor.state.gpuTemp == 51.2)
        #expect(monitor.state.ssdTemp == 38.9)
        // Fans publish in id order regardless of payload order.
        #expect(monitor.state.fanRPMs == [2745.0, 3006.0])
        #expect(monitor.state.modeRaw == "curve")
        #expect(monitor.state.selection == .quiet)
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

    @Test func selectionMappingCoversOnlyTheThreeOwnedCommands() throws {
        let cases: [(String, String?, FanControlMode?)] = [
            ("auto", nil, .auto),
            ("curve", "quiet", .quiet),
            ("curve", "aggressive", .performance),
            ("curve", "balanced", nil),
            ("curve", "custom", nil),
            ("curve", nil, nil),
            ("ai", nil, nil),
            ("manual", nil, nil),
        ]
        for (mode, preset, expected) in cases {
            var config: [String: Any] = ["mode": mode]
            if let preset { config["preset"] = preset }
            let (monitor, _) = try makeFixture(status: freshStatus(), config: config)
            monitor.refresh()
            #expect(
                monitor.state.selection == expected,
                "mode=\(mode) preset=\(preset ?? "nil")"
            )
        }
    }

    @Test func applyQuietWritesPresetAndCurveButPreservesForeignKeys() throws {
        let config: [String: Any] = [
            "mode": "ai",
            "aiTargetTemp": 72,
            "quietHours": true,
            "manualPercent": 30,
            "nightCurve": [["temp": 59.0, "percent": 0.0]],
        ]
        let (monitor, dir) = try makeFixture(status: freshStatus(), config: config)

        #expect(monitor.apply(.quiet))

        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("config.json"))
        ) as? [String: Any]
        #expect(written?["mode"] as? String == "curve")
        #expect(written?["preset"] as? String == "quiet")
        #expect((written?["curve"] as? [[String: Any]])?.count == 5)
        // Foreign keys round-trip untouched.
        #expect(written?["aiTargetTemp"] as? Int == 72)
        #expect(written?["quietHours"] as? Bool == true)
        #expect(written?["manualPercent"] as? Int == 30)
        #expect((written?["nightCurve"] as? [[String: Any]])?.count == 1)
        #expect(monitor.state.selection == .quiet)
    }

    @Test func applyRefusesWhenExistingConfigIsUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanmonitor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: freshStatus())
            .write(to: dir.appendingPathComponent("status.json"))
        // No config.json at all (and, below, a corrupted one) must both refuse:
        // a partial write would decode-fail at the daemon and silently no-op.
        let monitor = FanMonitor(directory: dir)
        #expect(monitor.apply(.quiet) == false)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path))

        try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect(monitor.apply(.auto) == false)
        let stillCorrupt = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        #expect(stillCorrupt == Data("not json".utf8))
    }

    @Test func applyAutoKeepsEveryOtherKeyIncludingCustomCurve() throws {
        let custom = [["temp": 59.0, "percent": 0.0], ["temp": 88.0, "percent": 100.0]]
        let config: [String: Any] = [
            "mode": "curve", "preset": "custom", "curve": custom, "quietHours": true,
        ]
        let (monitor, dir) = try makeFixture(status: freshStatus(), config: config)

        #expect(monitor.apply(.auto))

        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("config.json"))
        ) as? [String: Any]
        #expect(written?["mode"] as? String == "auto")
        #expect(written?["preset"] as? String == "custom")
        #expect((written?["curve"] as? [[String: Any]])?.count == 2)
        #expect(written?["quietHours"] as? Bool == true)
        #expect(monitor.state.selection == .auto)
    }
}
