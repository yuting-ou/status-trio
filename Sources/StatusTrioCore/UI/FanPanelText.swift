import Foundation

/// Pure, testable text builders for the fan popover section. The view owns
/// layout only; every string with semantics lives here so the assertions can
/// pin it without rendering. MainActor-isolated because Localization is.
@MainActor
enum FanPanelText {

    // MARK: - Fan labels

    /// id 0 = 左, id 1 = 右 (FanCtl PanelModes convention) on dual-fan
    /// machines; otherwise 风扇N. Single-fan machines get no label at all.
    static func fanLabel(id: Int, total: Int, localization: Localization) -> String {
        if total == 2 {
            return localization.string(id == 0 ? .fanSideLeft : .fanSideRight)
        }
        return "\(localization.string(.fanSideFan))\(id + 1)"
    }

    private static func fanCount(_ state: FanPanelState) -> Int {
        max(state.expectedFanCount ?? 0, state.fans.count)
    }

    // MARK: - Readings lines

    static func tempsLine(state: FanPanelState) -> String {
        var parts = ["CPU \(temp(state.cpuTemp))", "GPU \(temp(state.gpuTemp))"]
        if let ssd = state.ssdTemp { parts.append("SSD \(temp(ssd))") }
        return parts.joined(separator: " · ")
    }

    private static func temp(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))°C"
    }

    /// Actual RPM per fan with explicit side labels. Placeholder rules (the
    /// honest daemon semantics): a missing entry or a declared fan-read fault
    /// means "no valid reading" → "—"; a present 0 means the fan is genuinely
    /// stopped and stays a real "0".
    static func rpmLine(
        state: FanPanelState, localization: Localization, labelsActual: Bool = false
    ) -> String {
        let total = fanCount(state)
        let readFailed = state.faultReasonRaw == "fanStateReadFailed"
        guard total > 0 else { return "— RPM" }

        func value(id: Int) -> String {
            guard !readFailed,
                  let fan = state.fans.first(where: { $0.id == id }),
                  let rpm = fan.actualRPM else { return "—" }
            return "\(Int(rpm.rounded()))"
        }

        let actualPrefix = labelsActual ? "\(localization.string(.fanActualPrefix)) " : ""
        if total == 1 {
            return actualPrefix + "\(value(id: state.fans.first?.id ?? 0)) RPM"
        }
        let segments = (0..<total).map { id in
            "\(fanLabel(id: id, total: total, localization: localization)) \(value(id: id))"
        }
        return actualPrefix + segments.joined(separator: " · ") + " RPM"
    }

    static func powerText(state: FanPanelState) -> String? {
        guard let watts = state.powerWatts else { return nil }
        return String(format: "%.1f W", watts)
    }

    // MARK: - Manual-mode annotation lines

    /// Daemon-computed target RPM, side-labeled; "—" where the daemon has no
    /// target for that fan (e.g. handback). nil when every fan's target
    /// already equals its actual reading — repeating the same numbers twice
    /// would read as a display bug, not as information.
    static func targetRpmLine(state: FanPanelState, localization: Localization) -> String? {
        let total = fanCount(state)
        guard total > 0 else { return nil }
        let allSettled = state.fans.allSatisfy { fan in
            guard let target = fan.targetRPM, let actual = fan.actualRPM else { return false }
            return abs(target - actual) < 1
        }
        guard !allSettled else { return nil }

        func value(id: Int) -> String {
            guard let fan = state.fans.first(where: { $0.id == id }),
                  let rpm = fan.targetRPM else { return "—" }
            return "\(Int(rpm.rounded()))"
        }
        let prefix = localization.string(.fanTargetPrefix)
        if total == 1 {
            return "\(prefix) \(value(id: state.fans.first?.id ?? 0)) RPM"
        }
        let segments = (0..<total).map { id in
            "\(fanLabel(id: id, total: total, localization: localization)) \(value(id: id))"
        }
        return "\(prefix) \(segments.joined(separator: " · ")) RPM"
    }

    /// RPM bounds per fan, side-labeled, read from status.json — never
    /// hardcoded. One line PER FAN: a joined line can wrap between a label
    /// and its value, which is exactly how "右" once ended up detached from
    /// its numbers on screen. Short lines that can never split mid-pair.
    static func rangeNoteLines(state: FanPanelState, localization: Localization) -> [String] {
        let prefix = localization.string(.fanRangePrefix)
        let total = fanCount(state)
        return (0..<total).compactMap { id in
            guard let range = state.fans.first(where: { $0.id == id })?.range else { return nil }
            let bounds = "\(Int(range.min))–\(Int(range.max)) RPM"
            return total <= 1
                ? "\(prefix) \(bounds)"
                : "\(prefix) \(fanLabel(id: id, total: total, localization: localization)) \(bounds)"
        }
    }

    // MARK: - Fault guidance

    /// Fault line, two clauses: what broke + what to do about it. Never a bare
    /// "something is wrong".
    static func faultLine(state: FanPanelState, localization: Localization) -> String? {
        guard state.controlFault, let raw = state.faultReasonRaw else { return nil }
        let reasonKey: LocalizationKey
        let guideKey: LocalizationKey
        switch raw {
        case "sensorUnavailable":
            reasonKey = .fanFaultSensorUnavailable
            guideKey = .fanFaultGuideSensor
        case "sensorImplausible":
            reasonKey = .fanFaultSensorImplausible
            guideKey = .fanFaultGuideSensor
        case "sensorBelowAmbient":
            reasonKey = .fanFaultSensorBelowAmbient
            guideKey = .fanFaultGuideSensor
        case "smcWriteFailed":
            reasonKey = .fanFaultSmcWriteFailed
            guideKey = .fanFaultGuideSmcWrite
        case "fanStateReadFailed":
            reasonKey = .fanFaultFanStateReadFailed
            guideKey = .fanFaultGuideFan
        case "fanFeedbackMismatch":
            reasonKey = .fanFaultFanFeedbackMismatch
            guideKey = .fanFaultGuideFan
        default:
            return "\(localization.string(.fanControlFault))（\(raw)）"
        }
        return "\(localization.string(reasonKey)) · \(localization.string(guideKey))"
    }

    // MARK: - Menu-bar badge

    /// Menu-bar attention level derived from the daemon's truth only.
    /// critical = control closed loop faulted; caution = a safety floor
    /// (failsafe / SSD / battery-hot) is actively overriding the user's mode.
    enum FanBadgeState: String, Equatable, Sendable {
        case hidden, caution, critical

        /// Shape differentiates the two alert levels without relying on hue
        /// (color-vision deficiency): caution is an open ring, critical a
        /// filled dot. Color stays as an additional channel.
        enum Shape: Equatable, Sendable {
            case ring, dot
        }

        var shape: Shape {
            switch self {
            case .hidden, .critical: return .dot
            case .caution: return .ring
            }
        }
    }

    static func badgeState(of state: FanPanelState) -> FanBadgeState {
        if state.controlFault { return .critical }
        if let reason = state.reasonRaw,
           reason == "failsafe" || reason == "ssd" || reason == "batteryHot" {
            return .caution
        }
        return .hidden
    }

    // MARK: - Header caption

    enum HeaderCaption: Equatable {
        /// Config intent not yet reflected in status.json: show the intended
        /// mode with a pending suffix instead of the stale daemon mode.
        case pending(FanModeChoice)
        case reason(LocalizationKey)
        case mode(FanModeChoice)
        case raw(String)
    }

    /// The controlling reason is the daemon's truth (safety floors override
    /// the user's mode), but only when status.json has caught up with the
    /// config; while they disagree the caption goes pending so the segmented
    /// control and the header can never name two different modes at once.
    /// A declared control fault outranks everything: with the closed loop
    /// broken the daemon has handed the fans back to macOS, and the header
    /// must say that — not the configured mode ("AI 自动接管" would be a lie).
    static func headerCaption(state: FanPanelState) -> HeaderCaption {
        if state.controlFault {
            return .reason(.fanReasonAIIdle)
        }
        if state.modePending, let selection = state.modeSelection {
            return .pending(selection)
        }
        if let reason = state.reasonRaw {
            switch reason {
            case "auto": return .reason(.fanSystemManaged)
            case "curve": return .reason(.fanReasonCurve)
            case "ai": return .reason(.fanReasonAI)
            case "aiIdle": return .reason(.fanReasonAIIdle)
            case "manual": return .reason(.fanReasonManual)
            case "battery": return .reason(.fanReasonBattery)
            case "night": return .reason(.fanReasonNight)
            case "batteryHot": return .reason(.fanReasonBatteryHot)
            case "quiet": return .reason(.fanReasonQuiet)
            case "ssd": return .reason(.fanReasonSSD)
            case "failsafe": return .reason(.fanReasonFailsafe)
            default: return .raw(reason)
            }
        }
        if let raw = state.modeRaw, let mode = FanModeChoice(rawValue: raw) {
            return .mode(mode)
        }
        if let selection = state.modeSelection {
            return .mode(selection)
        }
        return .raw("-")
    }
}
