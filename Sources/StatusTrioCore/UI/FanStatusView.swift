import SwiftUI

/// The fan section's block order — the single source both the view and the
/// order assertions read. The title row (icon + primary value + subtitle +
/// state line) is always first, then: controls → parameter help → footnotes.
enum FanSectionBlock: String, CaseIterable {
    case fault, modePicker, parameters, footnotes, writeError
    /// Declaration order IS the layout contract; tests pin it.
    static let order = FanSectionBlock.allCases
}

/// Fan section of the status popover. Layout mirrors the battery/Wi-Fi
/// sections exactly: title row = icon + headline primary value (actual RPM)
/// + caption subtitle (temps/power) + state line; everything below aligns to
/// the content column (icon right edge); controls before help text.
struct FanStatusView: View {
    @EnvironmentObject private var localization: Localization
    /// Observed directly: the popover's own `@ObservedObject var panel` does
    /// not republish when a nested object's `@Published` changes.
    @ObservedObject var monitor: FanMonitor
    /// While the slider is being dragged the local value leads; the debounced
    /// write lands in config.json a beat later and refresh() re-syncs.
    @State private var draggedPercent: Double?
    @State private var showInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: FanPanelState { monitor.state }

    var body: some View {
        VStack(alignment: .leading, spacing: StatusPanelSectionStyle.elementSpacing) {
            headerRow

            if !state.daemonAlive {
                // Two distinct offline truths: no status file at all (daemon
                // never ran) vs a file that stopped updating.
                Text(offlineText)
                    .font(StatusPanelSectionStyle.readingFont)
                    .foregroundStyle(FanPanelStyle.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(FanSectionBlock.order, id: \.self) { block in
                    switch block {
                    case .fault: faultRow
                    case .modePicker: modePicker
                    case .parameters: parameterRow
                    case .footnotes: footnoteRows
                    case .writeError: writeErrorRow
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15),
                   value: state.modeSelection)
    }

    // MARK: - Title row (icon + primary value + subtitle + state)

    private var headerRow: some View {
        HStack(spacing: StatusPanelSectionStyle.rowSpacing) {
            Image(systemName: SymbolFallback.name("fan", "wind"))
                .font(.system(size: StatusPanelSectionStyle.iconPointSize,
                              weight: StatusPanelSectionStyle.iconWeight))
                .foregroundStyle(.secondary)
                .frame(width: StatusPanelSectionStyle.iconFrame,
                       height: StatusPanelSectionStyle.iconFrame)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(FanPanelText.primaryRpmLine(
                    state: state, localization: localization))
                    .font(StatusPanelSectionStyle.titleFont)
                    .monospacedDigit()
                Text(FanPanelText.subtitleLine(state: state))
                    .font(StatusPanelSectionStyle.readingFont)
                    .monospacedDigit()
                    .foregroundStyle(FanPanelStyle.caption)
                    // Readings must never truncate: narrow columns wrap.
                    .fixedSize(horizontal: false, vertical: true)
                Text(stateLineText)
                    .font(StatusPanelSectionStyle.footnoteFont)
                    .foregroundStyle(FanPanelStyle.footnote)
                    .lineLimit(1)
            }

            Spacer()
            // No affordance on the right: there is no fan settings page yet
            // (tracked for P1). No dead gear icon.
        }
    }

    /// ③ Mode/reason/pending/fault-handback all live here now — never on the
    /// title row's right side.
    private var stateLineText: String {
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

    private var offlineText: String {
        if state.statusFilePresent, let age = state.statusAgeSeconds {
            return localization.format(.fanStaleData, Int(age.rounded(.down)))
        }
        return localization.string(.fanDaemonOffline)
    }

    // MARK: - Fault alert

    @ViewBuilder
    private var faultRow: some View {
        if let fault = FanPanelText.faultLine(state: state, localization: localization) {
            Text(fault)
                .font(StatusPanelSectionStyle.readingFont)
                .foregroundStyle(FanPanelStyle.fault)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, StatusPanelSectionStyle.contentLeadingInset)
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
        .padding(.leading, StatusPanelSectionStyle.contentLeadingInset)
    }

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
        VStack(alignment: .leading, spacing: StatusPanelSectionStyle.annotationSpacing) {
            switch state.modeSelection {
            case .curve:
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
            case .ai:
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
        .padding(.leading, StatusPanelSectionStyle.contentLeadingInset)
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
            EmptyView() // handback already shown in the state line
        } else if let learned = state.aiLearnedPercent {
            HStack(spacing: 4) {
                Text(localization.format(.fanLearnedAirflowShort, Int(learned.rounded())))
                    .font(StatusPanelSectionStyle.footnoteFont)
                    .monospacedDigit()
                    .foregroundStyle(FanPanelStyle.footnote)
                infoButton
            }
        }
    }

    // MARK: - Manual controls (slider mirrors the volume section's shape)

    /// ⓘ entry — tap or keyboard-activate for the explanation notes.
    private var infoButton: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.string(.fanInfoLabel))
        .help(localization.string(.fanInfoLabel))
        .popover(isPresented: $showInfo, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(FanPanelText.infoLines(state: state, localization: localization), id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(width: 240)
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: StatusPanelSectionStyle.annotationSpacing) {
            HStack(spacing: StatusPanelSectionStyle.blockSpacing) {
                Slider(
                    value: Binding(
                        get: { draggedPercent ?? state.manualPercent ?? 30 },
                        set: { value in
                            // No `step:` (tick marks would show); round to the
                            // same 5% grid in the setter instead.
                            let snapped = (value / 5).rounded() * 5
                            draggedPercent = snapped
                            monitor.setManualPercent(snapped)
                        }
                    ),
                    in: FanMonitor.manualPercentRange
                )
                .accessibilityLabel(localization.string(.fanReasonManual))
                .accessibilityValue(sliderAccessibilityValue)
                Text("\(Int((draggedPercent ?? state.manualPercent ?? 30).rounded()))%")
                    .font(StatusPanelSectionStyle.readingFont.monospacedDigit())
                    .foregroundStyle(FanPanelStyle.caption)
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            // Gear chips: adaptive grid — wraps to two rows instead of
            // clipping the 100% chip at narrow widths.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 46), spacing: 4)],
                spacing: 4
            ) {
                ForEach([0.0, 25.0, 50.0, 75.0, 100.0], id: \.self) { gear in
                    let current = draggedPercent ?? state.manualPercent ?? 30
                    let active = abs(current - gear) < 0.5
                    Button {
                        draggedPercent = gear
                        monitor.setManualPercent(gear)
                    } label: {
                        Text(gear == 0
                             ? "\(localization.string(.fanPresetQuiet)) 0%"
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
                        ? localization.string(.fanGearQuietA11y)
                        : "\(Int(gear))%")
                }
            }
            // The target line exists only when it differs from the actual
            // spin (else it would repeat the headline verbatim).
            if let targetLine = FanPanelText.targetRpmLine(state: state, localization: localization) {
                Text(targetLine)
                    .font(StatusPanelSectionStyle.footnoteFont)
                    .monospacedDigit()
                    .foregroundStyle(FanPanelStyle.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// VoiceOver on the slider hears both the value and what it maps to.
    private var sliderAccessibilityValue: String {
        let pct = Int((draggedPercent ?? state.manualPercent ?? 30).rounded())
        let target = FanPanelText.targetRpmLine(state: state, localization: localization) ?? ""
        return target.isEmpty ? "\(pct)%" : "\(pct)% · \(target)"
    }

    // MARK: - Footnotes (one range line + ⓘ for the explanation notes)

    @ViewBuilder
    private var footnoteRows: some View {
        if state.modeSelection == .manual {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(
                        FanPanelText.rangeFootnoteLines(
                            state: state, localization: localization, maxWidth: 268),
                        id: \.self
                    ) { line in
                        Text(line)
                            .font(StatusPanelSectionStyle.footnoteFont)
                            .monospacedDigit()
                            .foregroundStyle(FanPanelStyle.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                infoButton
            }
            .padding(.leading, StatusPanelSectionStyle.contentLeadingInset)
        }
    }

    // MARK: - Write-failure surface

    @ViewBuilder
    private var writeErrorRow: some View {
        if monitor.lastWriteError != nil {
            Text(localization.string(.fanWriteFailed))
                .font(StatusPanelSectionStyle.footnoteFont)
                .foregroundStyle(FanPanelStyle.fault)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, StatusPanelSectionStyle.contentLeadingInset)
        }
    }
}
