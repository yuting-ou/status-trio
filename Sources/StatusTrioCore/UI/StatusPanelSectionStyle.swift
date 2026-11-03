import SwiftUI

/// Shared section-style spec for the status popover, measured from the three
/// original sections (battery / network / volume):
///   rows: HStack spacing 10, VStack spacing 8 between a section's blocks
///   title: .headline; icon: SF Symbol 15pt medium inside a 24×24 target
///   readings: .caption; footnotes: .caption2; popover padding 14, width 330
///
/// The three original sections keep their own literals by design (upstream
/// owns them and upstream tests pin them); every NEW section consumes this
/// spec so spacing/typography/corner-radius stay uniform by construction.
enum StatusPanelSectionStyle {
    static let rowSpacing: CGFloat = 10
    static let blockSpacing: CGFloat = 8
    static let iconPointSize: CGFloat = 15
    static let iconFrame: CGFloat = 24
    static let iconWeight: Font.Weight = .medium
    static let titleFont: Font = .headline
    static let readingFont: Font = .caption
    static let footnoteFont: Font = .caption2
    /// Quick-gear chip corner radius (the fan section's only rounded parts).
    static let chipRadius: CGFloat = 6
    /// In-section element spacing below the title row.
    static let elementSpacing: CGFloat = 6
    /// Tighter spacing between stacked annotation lines.
    static let annotationSpacing: CGFloat = 4
    /// Content-column leading inset: everything below the title row aligns to
    /// the icon's right edge (icon frame 24 + row spacing 10), the same
    /// baseline the battery/Wi-Fi/volume value texts sit on.
    static let contentLeadingInset: CGFloat = 34
}
