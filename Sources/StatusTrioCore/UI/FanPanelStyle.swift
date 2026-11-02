import AppKit
import SwiftUI

/// WCAG 2.x relative-luminance contrast, pure and testable. sRGB only —
/// close enough for label colors, which are authored in sRGB.
enum WCAGContrast {
    static func ratio(foreground: NSColor, background: NSColor) -> Double {
        // System label colors carry alpha (e.g. secondaryLabel is black at
        // ~50%); measuring the raw color ignores the blend and reports a
        // meaningless 21:1. Composite over the background first — that is
        // what the display actually shows.
        let fg = composited(foreground: foreground, over: background)
        let l1 = luminance(fg)
        let l2 = luminance(background)
        let hi = max(l1, l2)
        let lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func composited(foreground: NSColor, over background: NSColor) -> NSColor {
        guard let f = foreground.usingColorSpace(.sRGB),
              let b = background.usingColorSpace(.sRGB) else { return foreground }
        let a = f.alphaComponent
        func blend(_ x: CGFloat, _ y: CGFloat) -> CGFloat { a * x + (1 - a) * y }
        return NSColor(srgbRed: blend(f.redComponent, b.redComponent),
                       green: blend(f.greenComponent, b.greenComponent),
                       blue: blend(f.blueComponent, b.blueComponent),
                       alpha: 1)
    }

    static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    /// Dynamic colors only resolve against the *current* appearance, so the
    /// measurement must run inside the appearance's drawing context.
    static func ratio(
        foreground: NSColor, background: NSColor, appearance: NSAppearance
    ) -> Double {
        var value: Double = 0
        appearance.performAsCurrentDrawingAppearance {
            value = ratio(foreground: foreground, background: background)
        }
        return value
    }
}

/// Fan-section color scale. Measured against NSColor.windowBackgroundColor in
/// FanPanelStyleTests — every value must hold ≥ 4.5:1 in BOTH appearances
/// (system .secondary/.tertiary label colors fail that on light backgrounds,
/// which is why these exist). The grays keep the system hierarchy (reading
/// darker than footnote), just on compliant stops. NSColor is the canonical
/// form so tests can measure the exact same value the view renders.
enum FanPanelStyle {
    /// Readings line (temperatures / RPM / power).
    static let captionNS = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.70, green: 0.70, blue: 0.72, alpha: 1)
            : NSColor(srgbRed: 0.33, green: 0.33, blue: 0.35, alpha: 1)
    })
    static let caption = Color(nsColor: captionNS)

    /// Footnote / annotation lines.
    static let footnoteNS = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1)
            : NSColor(srgbRed: 0.43, green: 0.43, blue: 0.46, alpha: 1)
    })
    static let footnote = Color(nsColor: footnoteNS)

    /// Fault guidance line — orange family, darkened until it passes.
    static let faultNS = NSColor(name: nil, dynamicProvider: { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1.00, green: 0.66, blue: 0.25, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.24, blue: 0.00, alpha: 1)
    })
    static let fault = Color(nsColor: faultNS)
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
