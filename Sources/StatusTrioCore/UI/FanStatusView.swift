import SwiftUI

/// Fan section of the status popover: a read-only view of the FanCtl daemon's
/// status.json plus mode/parameter commands that the daemon executes. Layout
/// follows the shared section rhythm (StatusPanelSectionStyle): title row →
/// controls body → annotation lines. All strings with semantics come from
/// FanPanelText so the tests can pin them without rendering.
struct FanStatusView: View {
    @EnvironmentObject private var localization: Localization
    /// Observed directly: the popover's own `@ObservedObject var panel` does
    /// not republish when a nested object's `@Published` changes.
    @ObservedObject var monitor: FanMonitor
    /// While the slider is being dragged the local value leads; the debounced
    /// write lands in config.json a beat later and refresh() re-syncs.
    @State private var draggedPercent: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: FanPanelState { monitor.state }

    var body: some View {
        VStack(alignment: .leading, spacing: StatusPanelSectionStyle.elementSpacing) {
            headerRow

            if !state.daemonAlive {
                // Two distinct offline truths: no status file at all (daemon
                // never ran) vs a file that stopped updating (daemon died or
                // hung — the last values must not pose as live).
                Text(offlineText)
                    .font(StatusPanelSectionStyle.readingFont)
                    .foregroundStyle(FanPanelStyle.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                modePicker
                parameterRow
                annotationRows
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15),
                   value: state.modeSelection)
    }

    // MARK: - Title row

    private var headerRow: some View {
        HStack(spacing: StatusPanelSectionStyle.rowSpacing) {
            Image(systemName: SymbolFallback.name("fan", "wind"))
                .font(.system(size: StatusPanelSectionStyle.iconPointSize,
                              weight: StatusPanelSectionStyle.iconWeight))
                .foregroundStyle(.teal)
                .frame(width: StatusPanelSectionStyle.iconFrame,
                       height: StatusPanelSectionStyle.iconFrame)
                .accessibilityHidden(true)

            Text(localization.string(.settingsPopupOrderFan))
                .font(StatusPanelSectionStyle.titleFont)

            Spacer()

            if state.daemonAlive {
                Text(headerCaptionText)
                    .font(StatusPanelSectionStyle.readingFont)
                    .foregroundStyle(FanPanelStyle.caption)
                    .lineLimit(1)
            }
        }
    }

    private var offlineText: String {
        if state.statusFilePresent, let age = state.statusAgeSeconds {
            return localization.format(.fanStaleData, Int(age.rounded(.down)))
        }
        return localization.string(.fanDaemonOffline)
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

    // MARK: - Controls body

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

    @ViewBuilder
    private var parameterRow: some View {
        switch state.modeSelection {
        case .curve:
            VStack(alignment: .leading, spacing: StatusPanelSectionStyle.annotationSpacing) {
                Picker("", selection: curveBinding) {
                    ForEach(FanCurveChoice.allCases) { preset in
                        Text(localization.string(preset.titleKey)).tag(Optional(preset))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(localization.string(.fanModeCurve))
                if state.curveIsCustom {
                    Text(localization.string(.fanCustomCurve))
                        .font(StatusPanelSectionStyle.footnoteFont)
                        .foregroundStyle(FanPanelStyle.footnote)
                }
            }
        case .ai:
            VStack(alignment: .leading, spacing: StatusPanelSectionStyle.annotationSpacing) {
                Picker("", selection: aiTargetBinding) {
                    ForEach(FanAITargetChoice.allCases) { target in
                        Text("\(localization.string(target.titleKey)) \(Int(target.rawValue))°C")
                            .tag(Optional(target))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(localization.string(.fanModeAI))
                Text(localization.string(.fanAITargetHint))
                    .font(StatusPanelSectionStyle.footnoteFont)
                    .foregroundStyle(FanPanelStyle.footnote)
                aiCaption
            }
        case .manual:
            manualControls
        case .auto:
            Text(localization.string(.fanSystemManaged))
                .font(StatusPanelSectionStyle.footnoteFont)
                .foregroundStyle(FanPanelStyle.footnote)
        case nil:
            Text(localization.format(.fanManagedExternally, state.modeRaw ?? "-"))
                .font(StatusPanelSectionStyle.footnoteFont)
                .foregroundStyle(FanPanelStyle.footnote)
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
                .font(StatusPanelSectionStyle.footnoteFont)
                .foregroundStyle(FanPanelStyle.footnote)
        } else if state.reasonRaw == "aiIdle" {
            Text(localization.string(.fanReasonAIIdle))
                .font(StatusPanelSectionStyle.footnoteFont)
                .foregroundStyle(FanPanelStyle.footnote)
        } else if let learned = state.aiLearnedPercent {
            // Self-explanatory on screen — the tooltip is supplementary only.
            Text(localization.format(.fanLearnedAirflowLine, Int(learned.rounded())))
                .font(StatusPanelSectionStyle.footnoteFont)
                .monospacedDigit()
                .foregroundStyle(FanPanelStyle.footnote)
                .help(localization.string(.fanLearnedAirflowHelp))
        }
    }

    // MARK: - Manual controls

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: StatusPanelSectionStyle.annotationSpacing) {
            HStack(spacing: StatusPanelSectionStyle.blockSpacing) {
                Text("\(Int((draggedPercent ?? state.manualPercent ?? 30).rounded()))%")
                    .font(StatusPanelSectionStyle.readingFont.weight(.semibold))
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
                .accessibilityLabel(localization.string(.fanReasonManual))
                .accessibilityValue(sliderAccessibilityValue)
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
                            .font(StatusPanelSectionStyle.footnoteFont
                                .weight(active ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(active ? Color.white : FanPanelStyle.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: StatusPanelSectionStyle.chipRadius,
                                    style: .continuous
                                )
                                .fill(active
                                      ? AnyShapeStyle(Color.accentColor.gradient)
                                      : AnyShapeStyle(FanPanelStyle.chipBackground))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(gear == 0
                        ? localization.string(.fanPresetQuiet)
                        : "\(Int(gear))%")
                }
            }
            // One line, one topic each: daemon-computed targets, then the
            // hardware range, then the percent semantics, then the safety net.
            Text(FanPanelText.targetRpmLine(state: state, localization: localization))
                .font(StatusPanelSectionStyle.footnoteFont)
                .monospacedDigit()
                .foregroundStyle(FanPanelStyle.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text(FanPanelText.rangeNoteLine(state: state, localization: localization))
                .font(StatusPanelSectionStyle.footnoteFont)
                .monospacedDigit()
                .foregroundStyle(FanPanelStyle.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text(localization.string(.fanManualZeroNote))
                .font(StatusPanelSectionStyle.footnoteFont)
                .foregroundStyle(FanPanelStyle.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Text(localization.string(.fanFailsafeNote))
                .font(StatusPanelSectionStyle.footnoteFont)
                .foregroundStyle(FanPanelStyle.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// VoiceOver on the slider hears both the value and what it maps to.
    private var sliderAccessibilityValue: String {
        let pct = Int((draggedPercent ?? state.manualPercent ?? 30).rounded())
        let target = FanPanelText.targetRpmLine(state: state, localization: localization)
        return target.isEmpty ? "\(pct)%" : "\(pct)% · \(target)"
    }

    // MARK: - Annotation rows (readings + fault)

    private var annotationRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(FanPanelText.tempsLine(state: state))
                .font(StatusPanelSectionStyle.readingFont)
                .monospacedDigit()
                .foregroundStyle(FanPanelStyle.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(rpmPowerLine)
                .font(StatusPanelSectionStyle.readingFont)
                .monospacedDigit()
                .foregroundStyle(FanPanelStyle.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let fault = FanPanelText.faultLine(state: state, localization: localization) {
                Text(fault)
                    .font(StatusPanelSectionStyle.readingFont)
                    .foregroundStyle(FanPanelStyle.fault)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if monitor.lastWriteError != nil {
                Text(localization.string(.fanWriteFailed))
                    .font(StatusPanelSectionStyle.footnoteFont)
                    .foregroundStyle(FanPanelStyle.fault)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rpmPowerLine: String {
        let rpm = FanPanelText.rpmLine(state: state, localization: localization)
        guard let power = FanPanelText.powerText(state: state) else { return rpm }
        return "\(rpm) · \(power)"
    }
}
