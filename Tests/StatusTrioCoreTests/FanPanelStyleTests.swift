import AppKit
import Foundation
import Testing
@testable import StatusTrioCore

/// Contrast of the fan-section palette, measured (never eyeballed) against
/// the window background in both appearances. Baseline fact these tests pin:
/// the system grays do NOT pass on light backgrounds — .secondaryLabel is
/// ~3.3:1 and .tertiaryLabel ~1.6:1 on white, which is exactly why the fan
/// footnotes were unreadable in the r2 screenshots.
struct FanPanelStyleTests {
    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    @Test func systemGraysFailOnLightSoThePaletteCannotReuseThem() {
        let bg = NSColor.windowBackgroundColor
        let secondary = WCAGContrast.ratio(
            foreground: .secondaryLabelColor, background: bg, appearance: light)
        let tertiary = WCAGContrast.ratio(
            foreground: .tertiaryLabelColor, background: bg, appearance: light)
        // Measured 2026-11-02 (alpha composited over white): secondary
        // ~3.9:1, tertiary ~1.9:1 — the documented motivation for the scale.
        #expect(secondary < 4.5, "secondary = \(secondary)")
        #expect(tertiary < 4.5, "tertiary = \(tertiary)")
    }

    @Test func captionFootnoteAndFaultPassOnBothAppearances() {
        let bg = NSColor.windowBackgroundColor
        for (appearance, name) in [(light, "light"), (dark, "dark")] {
            let caption = WCAGContrast.ratio(
                foreground: FanPanelStyle.captionNS, background: bg, appearance: appearance)
            let footnote = WCAGContrast.ratio(
                foreground: FanPanelStyle.footnoteNS, background: bg, appearance: appearance)
            let fault = WCAGContrast.ratio(
                foreground: FanPanelStyle.faultNS, background: bg, appearance: appearance)
            #expect(caption >= 4.5, "\(name) caption = \(caption)")
            #expect(footnote >= 4.5, "\(name) footnote = \(footnote)")
            #expect(fault >= 4.5, "\(name) fault = \(fault)")
        }
    }

    @Test func readingsStayDarkerThanFootnotesInBothAppearances() {
        for (appearance, name) in [(light, "light"), (dark, "dark")] {
            let caption = WCAGContrast.ratio(
                foreground: FanPanelStyle.captionNS,
                background: .windowBackgroundColor, appearance: appearance)
            let footnote = WCAGContrast.ratio(
                foreground: FanPanelStyle.footnoteNS,
                background: .windowBackgroundColor, appearance: appearance)
            // Hierarchy preserved: the readings line keeps MORE contrast than
            // the footnote, matching the system's caption>footnote order.
            #expect(caption > footnote, "\(name): caption \(caption) vs footnote \(footnote)")
        }
    }
}
