import SwiftUI

/// Fan section of the status popover: a read-only view of the FanCtl daemon's
/// status.json plus mode/parameter commands that the daemon executes. All
/// semantics — safety floors, slew rates, mode resolution, percent→RPM
/// mapping — stay behind the daemon; this view only renders and forwards
/// intent. Every control works in the daemon's own domain (four modes,
/// factory presets, three AI target gears, 0...100 manual percent), so no
/// value shown here can be rewritten by the daemon's clamps.
struct FanStatusView: View {
    @EnvironmentObject private var localization: Localization
    /// Observed directly: the popover's own `@ObservedObject var panel` does
    /// not republish when a nested object's `@Published` changes.
    @ObservedObject var monitor: FanMonitor
    /// While the slider is being dragged the local value leads; the debounced
    /// write lands in config.json a beat later and refresh() re-syncs.
    @State private var draggedPercent: Double?

    private var state: FanPanelState { monitor.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            if !state.daemonAlive {
                Text(localization.string(.fanDaemonOffline))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                readingsRows

                if state.controlFault {
                    Text(localization.string(.fanControlFault))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                modePicker
                parameterRow
            }
        }
    }

    // MARK: - Header (temperatures / RPM / power / controlling reason)

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: SymbolFallback.name("fan", "wind"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.teal)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            Text(localization.string(.settingsPopupOrderFan))
                .font(.headline)

            Spacer()

            if state.daemonAlive {
                Text(reasonCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var readingsRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tempsLine)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(rpmPowerLine)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var tempsLine: String {
        var parts = ["CPU \(temp(state.cpuTemp))", "GPU \(temp(state.gpuTemp))"]
        if let ssd = state.ssdTemp { parts.append("SSD \(temp(ssd))") }
        return parts.joined(separator: "  ·  ")
    }

    private var rpmPowerLine: String {
        var parts: [String] = []
        if !state.fanRPMs.isEmpty {
            parts.append(state.fanRPMs.map { "\(Int($0.rounded()))" }.joined(separator: " / ") + " RPM")
        }
        if let watts = state.powerWatts {
            parts.append(String(format: "%.1f W", watts))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Mode row

    private var modePicker: some View {
        Picker("", selection: modeBinding) {
            ForEach(FanModeChoice.allCases) { mode in
                Text(localization.string(mode.titleKey)).tag(Optional(mode))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(localization.string(.settingsPopupOrderFan))
    }

    /// nil selection means the config was shaped outside what this panel can
    /// express; the segmented row deliberately shows nothing rather than lie.
    private var modeBinding: Binding<FanModeChoice?> {
        Binding(
            get: { state.modeSelection },
            set: { mode in
                guard let mode else { return }
                draggedPercent = nil
                _ = monitor.setMode(mode)
            }
        )
    }

    // MARK: - Mode-specific parameter row

    @ViewBuilder
    private var parameterRow: some View {
        switch state.modeSelection {
        case .curve:
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: curveBinding) {
                    ForEach(FanCurveChoice.allCases) { preset in
                        Text(localization.string(preset.titleKey)).tag(Optional(preset))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if state.curveIsCustom {
                    Text(localization.string(.fanCustomCurve))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        case .ai:
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: aiTargetBinding) {
                    ForEach(FanAITargetChoice.allCases) { target in
                        Text("\(localization.string(target.titleKey)) \(Int(target.rawValue))°")
                            .tag(Optional(target))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                aiCaption
            }
        case .manual:
            manualControls
        case .auto:
            Text(localization.string(.fanSystemManaged))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case nil:
            Text(localization.format(.fanManagedExternally, state.modeRaw ?? "-"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var curveBinding: Binding<FanCurveChoice?> {
        Binding(
            get: { state.curveSelection },
            set: { preset in
                guard let preset else { return }
                _ = monitor.setCurvePreset(preset)
            }
        )
    }

    private var aiTargetBinding: Binding<FanAITargetChoice?> {
        Binding(
            get: { state.aiTargetSelection },
            set: { target in
                guard let target else { return }
                _ = monitor.setAITarget(target)
            }
        )
    }

    @ViewBuilder
    private var aiCaption: some View {
        if state.aiTargetSelection == nil, let raw = state.aiTargetRaw {
            Text("\(localization.string(.fanTargetPrefix)) \(Int(raw.rounded()))°C")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if state.reasonRaw == "aiIdle" {
            Text(localization.string(.fanReasonAIIdle))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if let learned = state.aiLearnedPercent {
            Text("\(localization.string(.fanExperiencePrefix)) \(Int(learned.rounded()))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.purple)
        }
    }

    // MARK: - Manual controls

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(Int((draggedPercent ?? state.manualPercent ?? 30).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { draggedPercent ?? state.manualPercent ?? 30 },
                        set: { value in
                            draggedPercent = value
                            monitor.setManualPercent(value)
                        }
                    ),
                    in: FanMonitor.manualPercentRange,
                    step: 5
                )
            }
            HStack(spacing: 6) {
                ForEach([0.0, 25.0, 50.0, 75.0, 100.0], id: \.self) { gear in
                    let current = draggedPercent ?? state.manualPercent ?? 30
                    let active = abs(current - gear) < 0.5
                    Button {
                        draggedPercent = gear
                        monitor.setManualPercent(gear)
                    } label: {
                        Text(gear == 0
                             ? localization.string(.fanPresetQuiet)
                             : "\(Int(gear))%")
                            .font(.caption2.weight(active ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(active ? Color.white : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(active
                                          ? AnyShapeStyle(Color.accentColor.gradient)
                                          : AnyShapeStyle(Color.secondary.opacity(0.08)))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(targetRpmLine)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(rangeNoteLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Daemon-computed target RPM (status.json) — the only honest target:
    /// percent→RPM mapping belongs to the daemon.
    private var targetRpmLine: String {
        guard !state.fanTargetRPMs.isEmpty else { return "" }
        let targets = state.fanTargetRPMs.map { "\(Int($0.rounded()))" }.joined(separator: " / ")
        return "→ \(targets) RPM"
    }

    /// Bounds read from status.json (fans[].minRPM/maxRPM), never hardcoded.
    private var rangeNoteLine: String {
        let ranges = state.fanRanges
            .map { "\(Int($0.min))–\(Int($0.max))" }
            .joined(separator: " / ")
        let rangeText = ranges.isEmpty ? "" : " · \(localization.string(.fanRangePrefix)) \(ranges) RPM"
        return localization.string(.fanManualNote) + rangeText
    }

    // MARK: - Captions

    /// The controlling reason is the daemon's truth (safety floors override
    /// the user's mode); fall back to the config mode name only when the
    /// daemon did not annotate a reason this beat.
    private var reasonCaption: String {
        if let reason = state.reasonRaw {
            switch reason {
            case "auto": return localization.string(.fanSystemManaged)
            case "curve": return localization.string(.fanReasonCurve)
            case "ai": return localization.string(.fanReasonAI)
            case "aiIdle": return localization.string(.fanReasonAIIdle)
            case "manual": return localization.string(.fanReasonManual)
            case "battery": return localization.string(.fanReasonBattery)
            case "night": return localization.string(.fanReasonNight)
            case "batteryHot": return localization.string(.fanReasonBatteryHot)
            case "quiet": return localization.string(.fanReasonQuiet)
            case "ssd": return localization.string(.fanReasonSSD)
            case "failsafe": return localization.string(.fanReasonFailsafe)
            default: break
            }
        }
        return modeCaption(state.modeRaw ?? "-")
    }

    private func modeCaption(_ raw: String) -> String {
        switch raw {
        case "auto": return localization.string(.fanModeAuto)
        case "curve": return localization.string(.fanModeCurve)
        case "ai": return localization.string(.fanModeAI)
        case "manual": return localization.string(.fanModeManual)
        default: return raw
        }
    }

    private func temp(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))°"
    }
}
