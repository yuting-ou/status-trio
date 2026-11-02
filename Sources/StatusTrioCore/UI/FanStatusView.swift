import SwiftUI

/// Fan section of the status popover: a read-only view of the FanCtl daemon's
/// status.json plus a three-way command row (Auto / Quiet / Performance) that
/// is executed by the daemon, never by this process. All semantics — safety
/// floors, slew rates, mode resolution — stay behind the daemon; this view
/// only renders and forwards intent.
struct FanStatusView: View {
    @EnvironmentObject private var localization: Localization
    /// Observed directly: the popover's own `@ObservedObject var panel` does
    /// not republish when a nested object's `@Published` changes.
    @ObservedObject var monitor: FanMonitor
    let onSetMode: (FanControlMode) -> Void

    private var state: FanPanelState { monitor.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: SymbolFallback.name("fan", "wind"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.teal)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                Text(localization.string(.settingsPopupOrderFan))
                    .font(.headline)

                Spacer()

                if state.daemonAlive, let mode = state.modeRaw {
                    Text(modeCaption(mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !state.daemonAlive {
                Text(localization.string(.fanDaemonOffline))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(readingsLine)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if state.controlFault {
                    Text(localization.string(.fanControlFault))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("", selection: selectionBinding) {
                    ForEach(FanControlMode.allCases) { mode in
                        Text(localization.string(mode.titleKey)).tag(Optional(mode))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(localization.string(.settingsPopupOrderFan))

                if state.selection == nil {
                    Text(localization.format(.fanManagedExternally, modeCaption(state.modeRaw ?? "-")))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// nil selection means the config was shaped outside our three commands;
    /// the segmented row deliberately shows nothing rather than claim one.
    private var selectionBinding: Binding<FanControlMode?> {
        Binding(
            get: { state.selection },
            set: { mode in
                if let mode { onSetMode(mode) }
            }
        )
    }

    private var readingsLine: String {
        var parts: [String] = []
        parts.append("CPU \(temp(state.cpuTemp))")
        parts.append("GPU \(temp(state.gpuTemp))")
        if let ssd = state.ssdTemp {
            parts.append("SSD \(temp(ssd))")
        }
        let rpm = state.fanRPMs.map { "\(Int($0.rounded()))" }.joined(separator: " / ")
        if !rpm.isEmpty {
            parts.append("\(rpm) RPM")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func temp(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    private func modeCaption(_ raw: String) -> String {
        switch raw {
        case "auto": return localization.string(.fanModeAuto)
        case "curve": return localization.string(.fanModeCurve)
        case "ai": return "AI"
        case "manual": return localization.string(.fanModeManual)
        default: return raw
        }
    }
}
