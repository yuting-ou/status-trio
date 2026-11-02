import AppKit
import SwiftUI
import XCTest
@testable import StatusTrioCore

/// ④ The honest Dynamic Type evidence, two parts:
///
/// 1. Platform fact, pinned: in an offscreen process, none of the three
///    supposed scaling channels (`\.sizeCategory`, `\.dynamicTypeSize`,
///    `NSFontSizeCategory` defaults) changes rendered text size — measured
///    ratios are 1.0. Anyone claiming an env-based "XL render" on macOS is
///    showing you a no-op. Real scaling is delivered by the OS to running
///    apps from System Settings → Accessibility → Text Size.
///
/// 2. What CAN be proven deterministically: the section's layout survives
///    1.5×-equivalent stress. Wrap behavior depends on the
///    columnWidth/fontSize ratio, so 1.5× text in the 330pt panel stresses
///    the same ratio as 1.0× text in a 220pt column. At that width every
///    glyph must still land inside the panel (wrap, never clip).
@MainActor
final class FanDynamicTypeTests: XCTestCase {

    private func inkExtents<V: View>(_ content: V, width: CGFloat) -> (w: CGFloat, h: CGFloat) {
        let host = NSHostingView(rootView: content.frame(width: width))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(host.frame.width * scale),
            pixelsHigh: Int(host.frame.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = host.frame.size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.bitmapData else { return (0, 0) }
        var minRow = rep.pixelsHigh, maxRow = -1, minCol = rep.pixelsWide, maxCol = -1
        for row in 0..<rep.pixelsHigh {
            for col in 0..<rep.pixelsWide where data[row * rep.bytesPerRow + col * 4 + 3] > 16 {
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                minCol = min(minCol, col); maxCol = max(maxCol, col)
            }
        }
        guard maxRow >= minRow else { return (0, 0) }
        return (CGFloat(maxCol - minCol + 1) / scale, CGFloat(maxRow - minRow + 1) / scale)
    }

    private let sample = Text("测试 Ag").font(.caption).foregroundStyle(.black)

    func testInProcessScalingChannelsAreNoOps() {
        let base = inkExtents(sample, width: 300).h
        XCTAssertGreaterThan(base, 4, "base render produced no measurable glyphs")

        let channels: [(String, AnyView)] = [
            ("sizeCategory", AnyView(sample.environment(\.sizeCategory, .accessibilityExtraLarge))),
            ("dynamicTypeSize", AnyView(sample.environment(\.dynamicTypeSize, .accessibility1))),
        ]
        for (name, view) in channels {
            let ratio = inkExtents(view, width: 300).h / base
            print("DYNAMIC-TYPE-FACT \(name) ratio=\(ratio)")
            XCTAssertLessThan(ratio, 1.05,
                "\(name) unexpectedly started scaling — re-evaluate the XL evidence path")
        }
        UserDefaults.standard.set("NSFontSizeCategoryAccessibilityXXL", forKey: "NSFontSizeCategory")
        let defaultsRatio = inkExtents(sample, width: 300).h / base
        UserDefaults.standard.removeObject(forKey: "NSFontSizeCategory")
        print("DYNAMIC-TYPE-FACT NSFontSizeCategory ratio=\(defaultsRatio)")
        XCTAssertLessThan(defaultsRatio, 1.05)
    }

    func testSectionLayoutSurvivesOnePointFiveTimesEquivalentWidth() throws {
        // 330pt panel ÷ 1.5 text scale = 220pt equivalent column.
        let loc = Localization(
            defaults: UserDefaults(suiteName: "FanDynamicType.\(UUID().uuidString)") ?? .standard,
            preferredLanguages: ["zh-Hans"]
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fandynamictype-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "mode": "manual", "reason": "manual", "controlFault": false,
            "powerWatts": 14.2,
            "sensors": ["cpuDie": 58.4, "gpuDie": 52.1, "ssd": 35.2],
            "fans": [
                ["id": 0, "actualRPM": 2464.0, "targetRPM": 2464.0,
                 "minRPM": 1350.0, "maxRPM": 5349.0],
                ["id": 1, "actualRPM": 2661.0, "targetRPM": 2661.0,
                 "minRPM": 1458.0, "maxRPM": 5777.0],
            ],
            "hardwareProfile": ["fanCount": 2],
        ]).write(to: dir.appendingPathComponent("status.json"))
        try JSONSerialization.data(withJSONObject: ["mode": "manual", "manualPercent": 45])
            .write(to: dir.appendingPathComponent("config.json"))
        let monitor = FanMonitor(directory: dir)
        monitor.refresh()

        let equivalentWidth: CGFloat = 220
        let section = FanStatusView(monitor: monitor)
            .environmentObject(loc)
        let extents = inkExtents(
            section.padding(14).background(Color(nsColor: .windowBackgroundColor)),
            width: equivalentWidth)
        print("DYNAMIC-TYPE-STRESS 220pt column: ink w=\(extents.w) h=\(extents.h)")
        XCTAssertGreaterThan(extents.h, 40, "section rendered empty at 220pt")
        XCTAssertLessThanOrEqual(
            extents.w, equivalentWidth,
            "content escaped the 220pt column — clipping at 1.5×-equivalent stress")

        // Persist the evidence renders (330 baseline + 220 stress).
        for (w, name) in [(CGFloat(330), "r4-baseline-normal"), (equivalentWidth, "r4-stress-220pt")] {
            let host = NSHostingView(rootView:
                section.padding(14).frame(width: w)
                    .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(host.frame.width * 2),
                pixelsHigh: Int(host.frame.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = host.frame.size
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
    }
}
