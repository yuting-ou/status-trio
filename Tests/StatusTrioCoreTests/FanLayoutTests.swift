import AppKit
import Foundation
import Testing
@testable import StatusTrioCore

/// Layout-level gates for the fan section: block order, per-fan range-line
/// width at the narrowest panel width, and the original sections' palette
/// source. These fail on code review regressions without needing screenshots.
@MainActor
struct FanLayoutTests {

    /// ① Live readings must sit above the controls — the panel's other
    /// sections all put the primary value directly under the title. The
    /// order is pinned in code, not in screenshots.
    @Test func sectionBlocksKeepReadingsAboveControls() {
        let order = FanSectionBlock.order
        let i = { (block: FanSectionBlock) in order.firstIndex(of: block)! }
        #expect(i(.readings) < i(.modePicker))
        #expect(i(.modePicker) < i(.parameters))
        #expect(i(.parameters) < i(.writeError))
        #expect(order == [.readings, .modePicker, .parameters, .writeError])
    }

    /// ③ The joined range line once wrapped between a label and its value
    /// ("右" detached from its numbers). Per-fan lines must each contain
    /// their own label AND fit inside the panel's text width at the narrow
    /// (and only) panel width, measured with the actual footnote font proxy
    /// — a rendering-level check, not just a string-constant check.
    @Test func perFanRangeLinesCarryTheirLabelAndFitThePanel() {
        let loc = Localization(
            defaults: UserDefaults(suiteName: "FanLayoutTests.\(UUID().uuidString)") ?? .standard,
            preferredLanguages: ["zh-Hans"]
        )
        var s = FanPanelState()
        s.daemonAlive = true
        s.expectedFanCount = 2
        s.fans = [
            FanReading(id: 0, actualRPM: 2745, targetRPM: 2464,
                       range: FanRPMRange(min: 1350, max: 5349)),
            FanReading(id: 1, actualRPM: 3006, targetRPM: 2661,
                       range: FanRPMRange(min: 1458, max: 5777)),
        ]
        let lines = FanPanelText.rangeNoteLines(state: s, localization: loc)
        #expect(lines.count == 2)
        // Each line keeps its own label next to its own numbers.
        #expect(lines[0].contains("左") && lines[0].contains("1350–5349"))
        #expect(lines[1].contains("右") && lines[1].contains("1458–5777"))

        // Measured width at the footnote size must fit the 302pt text column
        // (330 panel − 2×14 padding), so a line can never wrap mid-pair.
        // .caption2 resolves to ~10pt on macOS; measure with the font the
        // text system actually uses for CJK+Latin mixes.
        let font = NSFont.systemFont(ofSize: 10)
        for line in lines {
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            #expect(width < 302, "「\(line)」 measures \(width)pt — would wrap")
        }
    }

    /// ② The original sections' subtitle/percentage texts must source their
    /// color from the measured palette — one scale for the whole panel.
    /// Guarded at source level because a foregroundStyle regression is
    /// invisible to behavior tests.
    @Test func originalSectionsSourceSubtitlesFromTheMeasuredPalette() {
        let files = [
            "BatteryStatusView.swift",
            "NetworkStatusView.swift",
            "VolumeControlsView.swift",
            "VPNStatusView.swift",
            "InputSourceStatusView.swift",
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // StatusTrioCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        for name in files {
            let url = root.appendingPathComponent(
                "Sources/StatusTrioCore/UI/\(name)")
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            #expect(
                content.contains(".foregroundStyle(FanPanelStyle.caption)"),
                "\(name) lost the measured-palette subtitle"
            )
        }
    }
}
