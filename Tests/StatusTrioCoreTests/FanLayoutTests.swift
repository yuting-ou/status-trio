import AppKit
import Foundation
import Testing
@testable import StatusTrioCore

/// Layout-level gates for the fan section: block order, content-column
/// baseline, slider shape, palette sourcing, primary-value weight.
@MainActor
struct FanLayoutTests {

    private func viewSource() -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent(
            "Sources/StatusTrioCore/UI/FanStatusView.swift"), encoding: .utf8)) ?? ""
    }

    /// ① The title row carries the live readings (headline RPM + caption
    /// temps), controls come after it, footnotes last. Pinned in code.
    @Test func sectionBlocksKeepControlsBelowReadingsAndHelpLast() {
        let order = FanSectionBlock.order
        let i = { (block: FanSectionBlock) in order.firstIndex(of: block)! }
        #expect(i(.fault) < i(.modePicker))
        #expect(i(.modePicker) < i(.parameters))
        #expect(i(.parameters) < i(.footnotes))
        #expect(i(.footnotes) < i(.writeError))
        #expect(order == [.fault, .modePicker, .parameters, .footnotes, .writeError])
    }

    /// ① Primary value is the headline-weight RPM line — same visual weight
    /// as battery's 100% and Wi-Fi's name. Source-level guard: a font change
    /// is invisible to behavior tests.
    @Test func primaryValueRendersAtTitleWeight() {
        let source = viewSource()
        #expect(source.contains("FanPanelText.primaryRpmLine("))
        #expect(source.contains(".font(StatusPanelSectionStyle.titleFont)"))
        // And the primary line is built from actual RPM, not a temperature.
        #expect(FanPanelText.primaryRpmLine(
            state: {
                var s = FanPanelState(); s.daemonAlive = true
                s.fans = [FanReading(id: 0, actualRPM: 2464, targetRPM: nil,
                                     range: FanRPMRange(min: 1350, max: 5349))]
                return s
            }(),
            localization: Localization(
                defaults: UserDefaults(suiteName: "FanLayout.\(UUID().uuidString)") ?? .standard,
                preferredLanguages: ["zh-Hans"])
        ) == "2464 RPM")
    }

    /// ② One content baseline: everything below the title row starts at the
    /// icon's right edge (iconFrame 24 + rowSpacing 10 = 34pt inset).
    @Test func contentColumnBaselineIsShared() {
        #expect(StatusPanelSectionStyle.contentLeadingInset
            == StatusPanelSectionStyle.iconFrame + StatusPanelSectionStyle.rowSpacing)
        #expect(StatusPanelSectionStyle.contentLeadingInset == 34)
        let source = viewSource()
        #expect(source.contains(".padding(.leading, StatusPanelSectionStyle.contentLeadingInset)"))
    }

    /// ⑥ The manual slider mirrors the volume slider's shape: no leading
    /// percent label, no tick marks, percent trailing at caption size.
    @Test func manualSliderMatchesVolumeSliderShape() {
        let source = viewSource()
        #expect(source.contains(".frame(minWidth: 34, alignment: .trailing)"))
        #expect(!source.contains(".frame(minWidth: 34, alignment: .leading)"))
        // No step argument -> no tick marks under the slider.
        #expect(!source.contains("in: FanMonitor.manualPercentRange,\n                    step:"))
    }

    /// ②(窄宽) Readings never truncate and gear chips wrap instead of
    /// clipping: subtitle must wrap (no tail/middle truncation), chips must
    /// be an adaptive grid, and the quiet chip names its percent.
    @Test func narrowWidthNeverHidesReadingsOrGears() {
        let source = viewSource()
        // Subtitle wraps: no lineLimit(1)/truncation on the subtitle line.
        #expect(source.contains("FanPanelText.subtitleLine(state: state))\n")
            && !source.contains(".truncationMode(.middle)"))
        // Chips: adaptive grid with a minimum that fits "安静 0%" / "100%".
        #expect(source.contains("LazyVGrid"))
        #expect(source.contains("GridItem(.adaptive(minimum: 52)"))
        #expect(source.contains("\"\\(localization.string(.fanPresetQuiet)) 0%\""))
    }

    /// ③ The title row's right side holds no status text.
    @Test func titleRowRightSideHasNoStatusText() {
        let source = viewSource()
        #expect(!source.contains("Spacer()\n\n            if state.daemonAlive {\n                Text(headerCaptionText)"))
    }

    /// ② (continued) The original sections' subtitle/percentage texts must
    /// source their color from the measured palette.
    @Test func originalSectionsSourceSubtitlesFromTheMeasuredPalette() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["BatteryStatusView.swift", "NetworkStatusView.swift",
                     "VolumeControlsView.swift", "VPNStatusView.swift",
                     "InputSourceStatusView.swift"] {
            let content = (try? String(contentsOf: root.appendingPathComponent(
                "Sources/StatusTrioCore/UI/\(name)"), encoding: .utf8)) ?? ""
            #expect(content.contains(".foregroundStyle(FanPanelStyle.caption)"),
                    "\(name) lost the measured-palette subtitle")
        }
    }
}
