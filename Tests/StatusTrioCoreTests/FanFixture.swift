import Foundation
@testable import StatusTrioCore

/// Fixture discipline for fan-section evidence renders (R7 rule):
/// numbers are never hand-written. Every fixture is built through these
/// builders, which derive RPM targets from the daemon's own mapping
/// (expectedTargetRPM) — fabricating a "nice-looking" number is impossible
/// by construction. A validator additionally flags any raw dict that
/// violates the mapping, so hand-rolled fixtures get caught too.
///
/// 截图是证据，不是示意图。数值造假等同于测试造假。
@MainActor
enum FanFixture {

    static let defaultRanges: [FanRPMRange] = [
        FanRPMRange(min: 1350, max: 5349), // 左 (id 0)
        FanRPMRange(min: 1458, max: 5777), // 右 (id 1)
    ]

    /// Steady manual state: targets == the exact mapping for `percent`,
    /// actuals == targets (a settled machine).
    static func settledManual(
        percent: Double, ranges: [FanRPMRange] = defaultRanges
    ) -> (status: [String: Any], config: [String: Any]) {
        let targets = ranges.map { FanPanelText.expectedTargetRPM(range: $0, percent: percent) }
        return manual(percent: percent, actuals: targets, targets: targets, ranges: ranges)
    }

    /// Mid-ramp manual state: targets are an earlier, still-converging value.
    /// Such a fixture MUST render as pending — the validator enforces that
    /// ramping fixtures can never pose as settled.
    static func rampingManual(
        percent: Double, rampTargets: [Double], ranges: [FanRPMRange] = defaultRanges
    ) -> (status: [String: Any], config: [String: Any]) {
        manual(percent: percent, actuals: rampTargets, targets: rampTargets, ranges: ranges)
    }

    static func manual(
        percent: Double, actuals: [Double], targets: [Double],
        ranges: [FanRPMRange] = defaultRanges
    ) -> (status: [String: Any], config: [String: Any]) {
        let fans: [[String: Any]] = zip(zip(actuals, targets), ranges).enumerated().map { index, pair in
            let ((actual, target), range) = pair
            return [
                "id": index,
                "actualRPM": actual,
                "targetRPM": target,
                "minRPM": range.min,
                "maxRPM": range.max,
            ] as [String: Any]
        }
        let status: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "mode": "manual", "reason": "manual", "controlFault": false,
            "powerWatts": 14.2,
            "sensors": ["cpuDie": 58.4, "gpuDie": 52.1, "ssd": 35.2],
            "fans": fans,
            "hardwareProfile": ["fanCount": ranges.count],
        ]
        let config: [String: Any] = ["mode": "manual", "manualPercent": percent]
        return (status, config)
    }

    // MARK: - Guard

    /// Every consistency issue found, human-readable. Empty = consistent.
    static func consistencyIssues(
        status: [String: Any], config: [String: Any]
    ) -> [String] {
        guard (config["mode"] as? String) == "manual",
              let percent = config["manualPercent"] as? Double
        else { return [] }
        // Offsets legitimately shift targets; the mapping check only applies
        // to zero-offset fixtures.
        let offsets = (config["fanOffsets"] as? [Double]) ?? []
        guard offsets.allSatisfy({ abs($0) < 0.01 }) else { return [] }

        guard let fans = status["fans"] as? [[String: Any]] else { return [] }
        return fans.compactMap { fan in
            guard let id = fan["id"] as? Int,
                  let target = fan["targetRPM"] as? Double,
                  let minRPM = fan["minRPM"] as? Double,
                  let maxRPM = fan["maxRPM"] as? Double
            else { return nil }
            let expected = FanPanelText.expectedTargetRPM(
                range: FanRPMRange(min: minRPM, max: maxRPM), percent: percent)
            guard abs(target - expected) <= 2 else {
                return "fan \(id): targetRPM \(Int(target)) ≠ round(\(Int(minRPM)) + \(Int(percent))% × (\(Int(maxRPM))−\(Int(minRPM)))) = \(Int(expected))（目标/百分比/范围三元组不满足映射）"
            }
            return nil
        }
    }
}
