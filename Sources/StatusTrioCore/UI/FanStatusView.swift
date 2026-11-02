import SwiftUI

/// Fan section of the status popover: a read-only view of the FanCtl daemon's
/// status.json plus mode/parameter commands that the daemon executes. All
/// semantics — safety floors, slew rates, mode resolution, percent→RPM
/// mapping — stay behind the daemon; this view only renders and forwards
/// intent. All strings with semantics come from FanPanelText so the tests can
/// pin them without rendering.
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

                if let fault = FanPanelText.faultLine(state: state, localization: localization) {
                    Text(fault)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
                Text(headerCaptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var headerCaptionText: String {
        switch FanPanelText.headerCaption(state: state) {
        case .pending(let mode):
            return "\(localization.string(mode.titleKey)) · \(localization.string(.fanPendingSuffix))"
        case .reason(let key):
            return localization.string(key)
        case .mode(let mode):
            return localization.string(mode.titleKey)
        case .raw(let text):
            return text
        }
    }

    private var readingsRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(FanPanelText.tempsLine(state: state))
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

    private var rpmPowerLine: String {
        let rpm = FanPanelText.rpmLine(state: state, localization: localization)
        guard let power = FanPanelText.powerText(state: state) else { return rpm }
        return "\(rpm)  ·  \(power)"
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
            Text("\(localization.string(.fanLearnedAirflow)) \(Int(learned.rounded()))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.purple)
                .help(localization.string(.fanLearnedAirflowHelp))
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
            // One line, one topic each: daemon-computed targets, then the
            // hardware range, then the percent semantics, then the safety net.
            Text(FanPanelText.targetRpmLine(state: state, localization: localization))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(FanPanelText.rangeNoteLine(state: state, localization: localization))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(localization.string(.fanManualZeroNote))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(localization.string(.fanFailsafeNote))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
