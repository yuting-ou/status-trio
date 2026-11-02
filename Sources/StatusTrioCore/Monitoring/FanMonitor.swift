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
///   a co-owner of the file.
enum FanControlMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case quiet
    case performance

    var id: Self { self }

    var titleKey: LocalizationKey {
        switch self {
        case .auto: .fanModeAuto
        case .quiet: .fanModeQuiet
        case .performance: .fanModePerformance
        }
    }
}

struct FanPanelState: Equatable, Sendable {
    /// The daemon wrote status.json within the staleness window.
    var daemonAlive = false
    /// nil when the reading is absent or implausible (e.g. sensor fault writes 0).
    var cpuTemp: Double?
    var gpuTemp: Double?
    var ssdTemp: Double?
    /// Actual RPM per fan, in fan-id order.
    var fanRPMs: [Double] = []
    /// Raw daemon mode ("auto" / "curve" / "ai" / "manual"), for the caption.
    var modeRaw: String?
    /// SMC write closed-loop failure reported by the daemon.
    var controlFault = false
    /// Which of our three commands the current config.json maps to, if any.
    /// nil = the config was shaped elsewhere (AI target, custom preset, manual
    /// percent…) and the segmented control shows no selection instead of lying.
    var selection: FanControlMode?
}

@MainActor
final class FanMonitor: ObservableObject {
    @Published private(set) var state = FanPanelState()

    private let directory: URL
    private let statusURL: URL
    private let configURL: URL
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fallbackTimer: DispatchSourceTimer?

    /// Newer than this and the daemon is considered alive; mirrors fanprobe's
    /// freshness bound (daemon writes at least every 10 s, 30 s = missed three).
    private static let stalenessWindow: TimeInterval = 30
    private static let fallbackInterval: TimeInterval = 10
    /// Main-queue only (both call sites), so the shared formatter needs no lock.
    private static let iso8601 = ISO8601DateFormatter()

    /// FanCtl's factory curves (SMCCore/Config.swift CurvePreset.points), the
    /// exact payloads the 清风 app itself writes when its own preset is picked.
    private static let quietCurve: [[String: Double]] = [
        ["temp": 55, "percent": 0], ["temp": 66, "percent": 12],
        ["temp": 75, "percent": 35], ["temp": 83, "percent": 65],
        ["temp": 89, "percent": 100],
    ]
    private static let aggressiveCurve: [[String: Double]] = [
        ["temp": 48, "percent": 0], ["temp": 58, "percent": 32],
        ["temp": 66, "percent": 60], ["temp": 74, "percent": 85],
        ["temp": 80, "percent": 100],
    ]

    init(directory: URL = URL(fileURLWithPath: "/Library/Application Support/FanCtl")) {
        self.directory = directory
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

    /// Write one of the three supported intents into config.json and let the
    /// daemon execute it. Read-modify-write: every key we do not own (custom
    /// curves, quiet-hours, AI target, offsets, boost deadlines) round-trips
    /// untouched, and the daemon's own sanitizers clamp anything we got wrong.
    ///
    /// - auto: `mode=auto` — hands fan control back to macOS.
    /// - quiet / performance: `mode=curve` with FanCtl's factory preset points,
    ///   matching what the 清风 app writes when its own preset is chosen. This
    ///   replaces the materialized `curve` array; users of a hand-tuned curve
    ///   keep it only if they stay on FanCtl's own UI.
    @discardableResult
    func apply(_ mode: FanControlMode) -> Bool {
        var config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL)))
            as? [String: Any] ?? [:]
        switch mode {
        case .auto:
            config["mode"] = "auto"
        case .quiet:
            config["mode"] = "curve"
            config["preset"] = "quiet"
            config["curve"] = Self.quietCurve
        case .performance:
            config["mode"] = "curve"
            config["preset"] = "aggressive"
            config["curve"] = Self.aggressiveCurve
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        guard Self.writeAtomically(data, to: configURL) else { return false }
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

        let stamp = (status["timestamp"] as? String)
            .flatMap { Self.iso8601.date(from: $0) }
        next.daemonAlive = stamp.map { Date().timeIntervalSince($0) < stalenessWindow } ?? false

        if let sensors = status["sensors"] as? [String: Any] {
            next.cpuTemp = plausible(sensors["cpuDie"])
            next.gpuTemp = plausible(sensors["gpuDie"])
            next.ssdTemp = plausible(sensors["ssd"])
        }
        if let fans = status["fans"] as? [[String: Any]] {
            next.fanRPMs = fans
                .sorted { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
                .compactMap { $0["actualRPM"] as? Double }
        }
        next.modeRaw = status["mode"] as? String
        next.controlFault = status["controlFault"] as? Bool ?? false

        if let configData = try? Data(contentsOf: configURL),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            next.selection = selection(from: config)
        }
        return next
    }

    /// A sensor reading of exactly 0 °C is the daemon's fault marker, not air
    /// temperature; negative and NaN payloads are rejected the same way.
    private static func plausible(_ value: Any?) -> Double? {
        guard let v = value as? Double, v.isFinite, v > 0, v < 150 else { return nil }
        return v
    }

    private static func selection(from config: [String: Any]) -> FanControlMode? {
        switch config["mode"] as? String {
        case "auto":
            return .auto
        case "curve":
            switch config["preset"] as? String {
            case "quiet": return .quiet
            case "aggressive": return .performance
            default: return nil
            }
        default:
            return nil
        }
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
