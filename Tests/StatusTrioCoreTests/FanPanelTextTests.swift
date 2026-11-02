import Foundation
import Testing
@testable import StatusTrioCore

/// String-level assertions for the fan section: every caption that carries
/// semantics is pinned here (zh-Hans), so a UI drift fails without rendering.
@MainActor
struct FanPanelTextTests {
    private func makeLocalization() -> Localization {
        let name = "FanPanelTextTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        return Localization(defaults: defaults, preferredLanguages: ["zh-Hans"])
    }

    private func twoFanState() -> FanPanelState {
        var s = FanPanelState()
        s.daemonAlive = true
        s.expectedFanCount = 2
        s.fans = [
            FanReading(id: 0, actualRPM: 2745, targetRPM: 2464,
                       range: FanRPMRange(min: 1350, max: 5349)),
            FanReading(id: 1, actualRPM: 3006, targetRPM: 2661,
                       range: FanRPMRange(min: 1458, max: 5777)),
        ]
        return s
    }

    // MARK: - ③ Side-labeled RPM values

    /// D12/D13: one temperature unit style (°C everywhere) and one separator.
    @Test func tempsLineUsesCelsiusSuffixAndSingleSeparator() {
        var s = twoFanState()
        s.cpuTemp = 63.4
        s.gpuTemp = 51.2
        s.ssdTemp = 38.9
        #expect(FanPanelText.tempsLine(state: s) == "CPU 63°C · GPU 51°C · SSD 39°C")
        s.cpuTemp = nil
        #expect(FanPanelText.tempsLine(state: s) == "CPU — · GPU 51°C · SSD 39°C")
    }

    @Test func rpmLineLabelsLeftAndRightFans() {
        let loc = makeLocalization()
        #expect(FanPanelText.rpmLine(state: twoFanState(), localization: loc)
            == "左 2745 · 右 3006 RPM")
    }

    @Test func targetRpmLineLabelsLeftAndRightFans() {
        let loc = makeLocalization()
        #expect(FanPanelText.targetRpmLine(state: twoFanState(), localization: loc)
            == "目标 左 2464 · 右 2661 RPM")
    }

    @Test func rangeNoteLineLabelsEachFansBounds() {
        let loc = makeLocalization()
        #expect(FanPanelText.rangeNoteLine(state: twoFanState(), localization: loc)
            == "范围 左 1350–5349 · 右 1458–5777 RPM")
    }

    // MARK: - ② Placeholder vs genuine zero

    @Test func zeroRpmIsARealReadingNotAPlaceholder() {
        let loc = makeLocalization()
        var s = twoFanState()
        s.fans[0].actualRPM = 0
        s.fans[1].actualRPM = 0
        // Fans genuinely stopped (AI idle handback etc.) — show the real 0.
        #expect(FanPanelText.rpmLine(state: s, localization: loc) == "左 0 · 右 0 RPM")
    }

    @Test func missingFanEntryRendersPlaceholder() {
        let loc = makeLocalization()
        var s = twoFanState()
        s.fans.removeAll { $0.id == 1 } // daemon skipped fan 1: read failed
        #expect(FanPanelText.rpmLine(state: s, localization: loc) == "左 2745 · 右 — RPM")
    }

    @Test func declaredFanReadFaultMasksAllValues() {
        let loc = makeLocalization()
        var s = twoFanState()
        s.faultReasonRaw = "fanStateReadFailed"
        #expect(FanPanelText.rpmLine(state: s, localization: loc) == "左 — · 右 — RPM")
        // A *temperature* fault does NOT mask fan reads: those stay valid.
        s.faultReasonRaw = "sensorUnavailable"
        #expect(FanPanelText.rpmLine(state: s, localization: loc) == "左 2745 · 右 3006 RPM")
    }

    @Test func emptyFanListUsesExpectedCountForPlaceholders() {
        let loc = makeLocalization()
        var s = FanPanelState()
        s.daemonAlive = true
        s.expectedFanCount = 2
        #expect(FanPanelText.rpmLine(state: s, localization: loc) == "左 — · 右 — RPM")
        s.expectedFanCount = 1
        #expect(FanPanelText.rpmLine(state: s, localization: loc) == "— RPM")
    }

    // MARK: - ① Pending vs stable header caption

    @Test func pendingCaptionNamesIntentAndNeverTheStaleMode() {
        var s = twoFanState()
        s.modeSelection = .manual
        s.modeRaw = "ai"
        s.modePending = true
        #expect(FanPanelText.headerCaption(state: s) == .pending(.manual))
    }

    /// A1: with the closed loop faulted the daemon has handed fans back to
    /// macOS — the header must say THAT, not the configured mode name.
    @Test func faultedHeaderShowsHandbackNeverTheConfiguredMode() {
        var s = twoFanState()
        s.controlFault = true
        s.faultReasonRaw = "sensorUnavailable"
        s.modeRaw = "ai"
        s.modeSelection = .ai
        s.modePending = false
        s.reasonRaw = "ai" // stale reason from before the fault
        #expect(FanPanelText.headerCaption(state: s) == .reason(.fanReasonAIIdle))
        #expect(FanPanelText.headerCaption(state: s) != .reason(.fanReasonAI))

        // Even a safety-floor reason cannot outrank the fault handback.
        s.reasonRaw = "failsafe"
        #expect(FanPanelText.headerCaption(state: s) == .reason(.fanReasonAIIdle))
    }

    @Test func stableCaptionPrefersDaemonReasonThenMode() {
        var s = twoFanState()
        s.modeSelection = .manual
        s.modeRaw = "manual"
        s.modePending = false
        s.reasonRaw = "failsafe"
        // Safety floor outranks the mode label: the header must say so.
        #expect(FanPanelText.headerCaption(state: s) == .reason(.fanReasonFailsafe))

        s.reasonRaw = nil
        #expect(FanPanelText.headerCaption(state: s) == .mode(.manual))
    }

    /// The invariant the screenshot violated: whenever the caption and the
    /// segmented selection coexist in a stable state, they must agree — a
    /// mismatch is only ever rendered as "pending", never as a contradiction.
    @Test func stableCaptionNeverContradictsTheSelection() {
        for mode in FanModeChoice.allCases {
            var s = twoFanState()
            s.modeSelection = mode
            s.modeRaw = mode.rawValue
            s.modePending = false
            s.reasonRaw = nil
            let caption = FanPanelText.headerCaption(state: s)
            #expect(caption == .mode(mode), "mode=\(mode.rawValue)")
        }
    }

    @Test func unknownReasonFallsBackToRawText() {
        var s = twoFanState()
        s.modePending = false
        s.reasonRaw = "futureReason"
        #expect(FanPanelText.headerCaption(state: s) == .raw("futureReason"))
    }

    // MARK: - ⑥ Fault line: what broke + what to do

    @Test func faultLinePairsReasonWithGuidance() {
        let loc = makeLocalization()
        var s = twoFanState()
        s.controlFault = true

        s.faultReasonRaw = "sensorUnavailable"
        #expect(FanPanelText.faultLine(state: s, localization: loc)
            == "温度传感器不可用 · 已交还系统调度兜底，无需操作；若持续请查看日志")

        s.faultReasonRaw = "smcWriteFailed"
        #expect(FanPanelText.faultLine(state: s, localization: loc)
            == "SMC 写入失败 · 调速未生效，请重启守护进程（或重装 FanCtl）")

        s.faultReasonRaw = "fanFeedbackMismatch"
        #expect(FanPanelText.faultLine(state: s, localization: loc)
            == "风扇转速未跟随目标 · 请检查风扇硬件；持续异常请查看日志")

        s.faultReasonRaw = nil
        #expect(FanPanelText.faultLine(state: s, localization: loc) == nil)
        s.controlFault = false
        s.faultReasonRaw = "sensorUnavailable"
        #expect(FanPanelText.faultLine(state: s, localization: loc) == nil)
    }

    @Test func singleFanMachineHasNoSideLabels() {
        let loc = makeLocalization()
        var s = FanPanelState()
        s.daemonAlive = true
        s.expectedFanCount = 1
        s.fans = [FanReading(id: 0, actualRPM: 2745, targetRPM: 2464,
                             range: FanRPMRange(min: 1350, max: 5349))]
        #expect(FanPanelText.rpmLine(state: s, localization: loc) == "2745 RPM")
        #expect(FanPanelText.targetRpmLine(state: s, localization: loc) == "目标 2464 RPM")
        #expect(FanPanelText.rangeNoteLine(state: s, localization: loc)
            == "范围 1350–5349 RPM")
    }
}
