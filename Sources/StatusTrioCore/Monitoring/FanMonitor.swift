import Combine
import Foundation

/// Fan section data source: a read-only projection of the FanCtl (清风) daemon's
/// status.json plus a command path that writes config.json for the daemon to
/// execute. The daemon keeps exclusive ownership of SMC access, temperature
/// safety floors, slew-rate limiting and the watchdog; this type never touches
/// hardware and never bypasses the daemon's decision pipeline.
///
/// Contract (see FanCtl's SMCCore/Config.swift):
/// - `/Library/Application Support/FanCtl/status.json` — daemon → UI, rewritten
///   atomically on change (or at its heartbeat), `timestamp` ISO-8601; a file
///   older than 30 s means the daemon is gone (fanprobe uses the same bound).
/// - `/Library/Application Support/FanCtl/config.json` — UI → daemon, picked up
///   through the daemon's DispatchSource file watch with a 30 ms debounce.
///   Unknown keys are preserved by read-modify-write so FanCtl's own app stays
///   a co-owner of the file. Every value the UI can emit stays inside the
///   domain the daemon's `sanitized()` accepts, so a shown value can never be
///   rewritten by the daemon's clamps.
enum FanModeChoice: String, CaseIterable, Identifiable, Sendable {
    case auto, curve, ai, manual

    var id: Self { self }

    var titleKey: LocalizationKey {
        switch self {
        case .auto: .fanModeAuto
        case .curve: .fanModeCurve
        case .ai: .fanModeAI
        case .manual: .fanModeManual
        }
    }
}

/// FanCtl's factory curve presets (SMCCore/Config.swift CurvePreset.points) —
/// the exact payloads the 清风 app writes when its own preset is picked.
enum FanCurveChoice: String, CaseIterable, Identifiable, Sendable {
    case quiet, balanced, aggressive

    var id: Self { self }

    var titleKey: LocalizationKey {
        switch self {
        case .quiet: .fanPresetQuiet
        case .balanced: .fanPresetBalanced
        case .aggressive: .fanPresetAggressive
        }
    }

    var points: [[String: Double]] {
        switch self {
        case .quiet:
            return [["temp": 55, "percent": 0], ["temp": 66, "percent": 12],
                    ["temp": 75, "percent": 35], ["temp": 83, "percent": 65],
                    ["temp": 89, "percent": 100]]
        case .balanced:
            return [["temp": 52, "percent": 0], ["temp": 62, "percent": 20],
                    ["temp": 70, "percent": 45], ["temp": 78, "percent": 72],
                    ["temp": 85, "percent": 100]]
        case .aggressive:
            return [["temp": 48, "percent": 0], ["temp": 58, "percent": 32],
                    ["temp": 66, "percent": 60], ["temp": 74, "percent": 85],
                    ["temp": 80, "percent": 100]]
        }
    }

    /// config.json may carry a preset label whose materialized curve no longer
    /// matches the factory points (user-tuned or AI-personalized). Showing the
    /// preset as selected in that state would be a lie, so selection requires
    /// both the label and the points to agree.
    func matches(curve: [[String: Any]]) -> Bool {
        guard curve.count == points.count else { return false }
        for (actual, expected) in zip(curve, points) {
            guard let t = actual["temp"] as? Double, let p = actual["percent"] as? Double,
                  abs(t - expected["temp"]!) < 0.51, abs(p - expected["percent"]!) < 0.51
            else { return false }
        }
        return true
    }
}

/// FanCtl's AI target-temperature gears (FanCtlApp/PanelModes.swift:420-421).
enum FanAITargetChoice: Double, CaseIterable, Identifiable, Sendable {
    case performance = 72
    case balanced = 76
    case quiet = 80

    var id: Self { self }

    var titleKey: LocalizationKey {
        switch self {
        case .performance: .fanModePerformance
        case .balanced: .fanPresetBalanced
        case .quiet: .fanPresetQuiet
        }
    }
}

/// Hardware RPM bounds of one fan, read from status.json (never hardcoded).
struct FanRPMRange: Equatable, Sendable {
    var min: Double
    var max: Double
}

/// One fan's readings. The daemon skips a fan whose RPM keys fail to decode
/// (ControlEngine: allStates), so a missing entry IS the "no valid reading"
/// signal and must render as a placeholder — while actualRPM == 0 is a real
/// read (the fan is genuinely stopped) and must stay visible.
struct FanReading: Equatable, Sendable {
    var id: Int
    var actualRPM: Double?
    var targetRPM: Double?
    var range: FanRPMRange?
}

struct FanPanelState: Equatable, Sendable {
    /// The daemon wrote status.json within the staleness window.
    var daemonAlive = false
    /// Seconds since the status.json timestamp (for the "数据已过期" caption).
    var statusAgeSeconds: Double?
    /// False when status.json itself is missing (daemon never installed/ran).
    var statusFilePresent = false
    /// nil when the reading is absent or implausible (e.g. sensor fault writes 0).
    var cpuTemp: Double?
    var gpuTemp: Double?
    var ssdTemp: Double?
    var powerWatts: Double?
    var envTemp: Double?
    /// Per-fan readings keyed by hardware id (id 0 = 左, id 1 = 右 per FanCtl's
    /// PanelModes). Sparse: a fan that failed to read is absent, not zeroed.
    var fans: [FanReading] = []
    /// hardwareProfile.fanCount from status.json — how many fans the machine
    /// has, so a fully missing list still renders the right number of
    /// placeholders instead of pretending the machine is fanless.
    var expectedFanCount: Int?
    /// Raw daemon mode ("auto" / "curve" / "ai" / "manual") and control reason
    /// (auto/curve/ai/aiIdle/manual/battery/night/batteryHot/quiet/ssd/failsafe).
    var modeRaw: String?
    var reasonRaw: String?
    /// Raw ControlFaultReason (sensorUnavailable / fanStateReadFailed /
    /// smcWriteFailed / fanFeedbackMismatch / sensorImplausible /
    /// sensorBelowAmbient) for the guidance line.
    var faultReasonRaw: String?
    /// config.json and status.json disagree on the mode: the intent was
    /// written but the daemon's status has not caught up yet (status.json is
    /// rewritten on change, and the rewrite can lag in fault windows). While
    /// this is true the header shows a pending caption so the two mode
    /// indicators can never contradict each other.
    var modePending = false
    /// Manual-mode intent vs. daemon-reported targets disagree: the daemon
    /// ramps manual changes at 8%/beat, so a fresh slider value legitimately
    /// takes a few beats to materialize. During that window the UI must say
    /// 待生效, not pretend the shown target already equals the slider.
    var manualPercentPending = false
    /// The learned-map value for the current temperature (decisionTrace.learned),
    /// display only.
    var aiLearnedPercent: Double?
    /// SMC write closed-loop failure reported by the daemon.
    var controlFault = false

    // Config-derived selections (what the controls point at).
    var modeSelection: FanModeChoice?
    var curveSelection: FanCurveChoice?
    /// True when config says preset=X but the materialized points differ —
    /// the preset row shows no selection and the "custom curve" caption instead.
    var curveIsCustom = false
    var aiTargetSelection: FanAITargetChoice?
    /// The raw aiTargetTemp when it is none of the three gears (shown as caption).
    var aiTargetRaw: Double?
    var manualPercent: Double?
}

@MainActor
final class FanMonitor: ObservableObject {
    @Published private(set) var state = FanPanelState()
    /// Last control-write failure, shown in the UI instead of failing
    /// silently. nil after the next successful write.
    @Published private(set) var lastWriteError: String?

    private let statusURL: URL
    private let configURL: URL
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fallbackTimer: DispatchSourceTimer?
    /// Slider drags produce a stream of values; the daemon already debounces
    /// config events at 30 ms, and FanCtl's own app debounces slider writes at
    /// 80 ms — we hold 100 ms so a drag costs one write, not thirty.
    private var pendingManualWrite: Task<Void, Never>?

    /// The daemon clamps manualPercent to exactly this range
    /// (FanConfig.sanitized); the slider must span the same domain — wider
    /// would show values the daemon rewrites, narrower would hide gears.
    /// Single source of truth for the view's Slider bounds and this clamp.
    static let manualPercentRange: ClosedRange<Double> = 0...100

    /// Newer than this and the daemon is considered alive; mirrors fanprobe's
    /// freshness bound (daemon writes at least every 10 s, 30 s = missed three).
    private static let stalenessWindow: TimeInterval = 30
    private static let fallbackInterval: TimeInterval = 10
    private static let manualWriteDebounce: TimeInterval = 0.1
    /// Main-queue only (both call sites), so the shared formatter needs no lock.
    private static let iso8601 = ISO8601DateFormatter()

    init(directory: URL = URL(fileURLWithPath: "/Library/Application Support/FanCtl")) {
        statusURL = directory.appendingPathComponent("status.json")
        configURL = directory.appendingPathComponent("config.json")
    }

    func start() {
        guard sources.isEmpty, fallbackTimer == nil else { return }
        watch(url: statusURL)
        watch(url: configURL)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.fallbackInterval,
            repeating: Self.fallbackInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.resume()
        fallbackTimer = timer
        refresh()
    }

    func stop() {
        pendingManualWrite?.cancel()
        pendingManualWrite = nil
        sources.forEach { $0.cancel() }
        sources.removeAll()
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    /// Re-read both files and republish. Cheap (two small JSON files) and only
    /// triggered by filesystem events or the slow fallback timer.
    func refresh() {
        state = Self.readState(statusURL: statusURL, configURL: configURL)
    }

    // MARK: - Control (UI → daemon)

    /// Switch the daemon mode, preserving every other key (curve points, AI
    /// target, manual percent stay where the user left them — same semantics
    /// as FanCtl's own setMode).
    @discardableResult
    func setMode(_ mode: FanModeChoice) -> Bool {
        writeConfig { $0["mode"] = mode.rawValue }
    }

    /// Pick a factory curve preset: mode=curve + preset + materialized points,
    /// exactly what the 清风 app writes on a preset pick.
    @discardableResult
    func setCurvePreset(_ preset: FanCurveChoice) -> Bool {
        writeConfig {
            $0["mode"] = "curve"
            $0["preset"] = preset.rawValue
            $0["curve"] = preset.points
        }
    }

    /// Pick an AI target temperature: mode=ai + aiTargetTemp.
    @discardableResult
    func setAITarget(_ target: FanAITargetChoice) -> Bool {
        writeConfig {
            $0["mode"] = "ai"
            $0["aiTargetTemp"] = target.rawValue
        }
    }

    /// Manual fixed speed. The daemon's domain is 0...100 percent
    /// (Config.swift clamps the same range); the clamp here is defense in
    /// depth so no caller can ever emit a value the daemon would rewrite.
    /// Debounced: safe to call on every slider tick.
    func setManualPercent(_ percent: Double) {
        let clamped = min(Self.manualPercentRange.upperBound,
                          max(Self.manualPercentRange.lowerBound,
                              percent.isFinite ? percent : Self.manualPercentRange.lowerBound))
        pendingManualWrite?.cancel()
        pendingManualWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.manualWriteDebounce * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.writeConfig {
                $0["mode"] = "manual"
                $0["manualPercent"] = clamped
            }
        }
    }

    /// Read-modify-write with an atomic same-directory replace. Bails out when
    /// the existing config cannot be read as an object: a partial write would
    /// decode-fail at the daemon (manualPercent/curve are required FanConfig
    /// keys) and silently drop the user's intent.
    @discardableResult
    private func writeConfig(_ mutate: (inout [String: Any]) -> Void) -> Bool {
        guard let configData = try? Data(contentsOf: configURL),
              var config = (try? JSONSerialization.jsonObject(with: configData))
                as? [String: Any]
        else {
            lastWriteError = "read"
            return false
        }
        mutate(&config)
        guard let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        ) else {
            lastWriteError = "encode"
            return false
        }
        guard Self.writeAtomically(data, to: configURL) else {
            lastWriteError = "write"
            return false
        }
        lastWriteError = nil
        refresh()
        return true
    }

    /// Same-directory temp file + rename, so a reader (daemon or FanCtl app)
    /// never sees a truncated config. Permissions follow FanCtl's convention
    /// (0664, group inherited from the directory) best-effort.
    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // MARK: - Reading

    private static func readState(statusURL: URL, configURL: URL) -> FanPanelState {
        var next = FanPanelState()
        guard let statusData = try? Data(contentsOf: statusURL),
              let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        else { return next }
        next.statusFilePresent = true

        let stamp = (status["timestamp"] as? String)
            .flatMap { Self.iso8601.date(from: $0) }
        if let stamp {
            let age = Date().timeIntervalSince(stamp)
            next.statusAgeSeconds = age
            next.daemonAlive = age < stalenessWindow
        }

        if let sensors = status["sensors"] as? [String: Any] {
            next.cpuTemp = plausible(sensors["cpuDie"])
            next.gpuTemp = plausible(sensors["gpuDie"])
            next.ssdTemp = plausible(sensors["ssd"])
        }
        next.powerWatts = plausible(status["powerWatts"])
        next.envTemp = plausible(status["envTemp"])
        if let fans = status["fans"] as? [[String: Any]] {
            next.fans = fans.compactMap { fan in
                guard let id = fan["id"] as? Int else { return nil }
                var range: FanRPMRange?
                if let lo = fan["minRPM"] as? Double, let hi = fan["maxRPM"] as? Double,
                   lo.isFinite, hi.isFinite, hi > lo {
                    range = FanRPMRange(min: lo, max: hi)
                }
                return FanReading(
                    id: id,
                    actualRPM: finite(fan["actualRPM"]),
                    targetRPM: finite(fan["targetRPM"]),
                    range: range
                )
            }
            .sorted { $0.id < $1.id }
        }
        if let profile = status["hardwareProfile"] as? [String: Any],
           let count = profile["fanCount"] as? Int, count > 0 {
            next.expectedFanCount = count
        }
        next.modeRaw = status["mode"] as? String
        next.reasonRaw = status["reason"] as? String
        next.faultReasonRaw = status["faultReason"] as? String
        if let trace = status["decisionTrace"] as? [String: Any] {
            next.aiLearnedPercent = plausible(trace["learned"])
        }
        next.controlFault = status["controlFault"] as? Bool ?? false

        // Config values needed past the parse block (offsets feed the pending
        // check below).
        var fanOffsets: [Double] = [0, 0]
        if let configData = try? Data(contentsOf: configURL),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            fanOffsets = (config["fanOffsets"] as? [Double]) ?? [0, 0]
            next.modeSelection = (config["mode"] as? String).flatMap(FanModeChoice.init(rawValue:))
            if let presetRaw = config["preset"] as? String,
               let preset = FanCurveChoice(rawValue: presetRaw),
               let curve = config["curve"] as? [[String: Any]] {
                next.curveSelection = preset.matches(curve: curve) ? preset : nil
                next.curveIsCustom = next.curveSelection == nil
            }
            if let target = config["aiTargetTemp"] as? Double, target.isFinite {
                next.aiTargetRaw = target
                next.aiTargetSelection = FanAITargetChoice.allCases
                    .first { abs($0.rawValue - target) < 0.5 }
            }
            if let manual = config["manualPercent"] as? Double, manual.isFinite {
                next.manualPercent = min(100, max(0, manual))
            }
        }

        // Pending iff the daemon is alive and both sides name a mode that
        // differs. A missing modeRaw (pre-field daemon) cannot prove pending.
        if next.daemonAlive,
           let selection = next.modeSelection,
           let raw = next.modeRaw,
           let statusMode = FanModeChoice(rawValue: raw) {
            next.modePending = statusMode != selection
        }

        // Manual-percent pending: manual mode, no override reason in effect
        // (an active quiet/ssd/failsafe cap legitimately deviates), zero fan
        // offsets (offsets shift targets by design), and the daemon-reported
        // targets must match the daemon's own mapping for the configured
        // percent. Any deviation beyond rounding = the intent is still
        // ramping in.
        if next.daemonAlive, next.modeSelection == .manual,
           next.reasonRaw == nil || next.reasonRaw == "manual",
           let percent = next.manualPercent {
            let offsetsZero = fanOffsets.allSatisfy { abs($0) < 0.01 }
            if offsetsZero {
                next.manualPercentPending = next.fans.contains { fan in
                    guard let target = fan.targetRPM, let range = fan.range else { return false }
                    return abs(target - FanPanelText.expectedTargetRPM(range: range, percent: percent)) > 2
                }
            }
        }
        return next
    }

    /// A sensor reading of exactly 0 °C is the daemon's fault marker, not air
    /// temperature; negative and NaN payloads are rejected the same way.
    private static func plausible(_ value: Any?) -> Double? {
        guard let v = value as? Double, v.isFinite, v > 0, v < 150 else { return nil }
        return v
    }

    /// Finite check for RPM-like values (0 is a legitimate read here).
    private static func finite(_ value: Any?) -> Double? {
        guard let v = value as? Double, v.isFinite, v >= 0 else { return nil }
        return v
    }

    // MARK: - File watching

    /// The daemon replaces both files atomically (rename), so each event source
    /// must re-arm against the new inode after every delivery.
    private func watch(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.rearm(source: source, url: url)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    private func rearm(source: DispatchSourceFileSystemObject, url: URL) {
        source.cancel()
        sources.removeAll { $0 === source }
        watch(url: url)
    }
}
