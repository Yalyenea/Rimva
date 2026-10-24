import AppKit
import RimvaCore

struct ThemePalette {
    let background: NSColor
    let surface: NSColor
    let canvas: NSColor
    let elevated: NSColor
    let text: NSColor
    let secondary: NSColor
    let separator: NSColor
    /// Fills and outlines of active controls.
    let accent: NSColor
    /// Text and glyphs of active controls; a pale accent stays a fill only.
    let accentText: NSColor
    let onAccent: NSColor
    let selection: NSColor
    let secondaryAccent: NSColor
    let warning: NSColor
    let error: NSColor
}

enum AppTheme: String, CaseIterable, Identifiable {
    case rosePine, standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rosePine: "Rosé Pine"
        case .standard: L("标准")
        }
    }

    func palette(dark: Bool) -> ThemePalette {
        switch (self, dark) {
        // Rosé Pine Dawn: cream surfaces, warm gray selection, and gray-violet accents.
        case (.rosePine, false):
            ThemePalette(hex: [0xFEFAF1, 0xFFF5EC, 0xF7F0EA, 0xF7F0EA, 0x575278, 0x797593, 0xCDC1CB, 0xEA9D34, 0xB4637A],
                         accent: rgb(0x575278), accentText: rgb(0x575278), onAccent: rgb(0xFEFAF1),
                         selection: rgb(0xEEE8E3), secondaryAccent: rgb(0x575278))
        // Rosé Pine Moon: muted gray-violet fills with pale text on selected surfaces.
        case (.rosePine, true):
            ThemePalette(hex: [0x232136, 0x2A273F, 0x2A273F, 0x393552, 0xE0DEF4, 0x908CAA, 0x56526E, 0xF6C177, 0xEB6F92],
                         accent: rgb(0x908CAA), accentText: rgb(0xE0DEF4), onAccent: rgb(0x232136),
                         selection: rgb(0x393552), secondaryAccent: rgb(0x908CAA))
        // Neutral grays leave the macOS accent as the only hue.
        case (.standard, false):
            standard(hex: [0xF5F5F6, 0xF5F5F6, 0xFCFCFC, 0xE8E8EA, 0x1F1F21, 0x6E6E73, 0xD8D8DB, 0xB26A00, 0xC93C37])
        case (.standard, true):
            standard(hex: [0x1E1E20, 0x1E1E20, 0x262628, 0x2F2F32, 0xE8E8EA, 0x9A9A9F, 0x3A3A3D, 0xE0A84A, 0xE5706B])
        }
    }

    private func standard(hex values: [UInt32]) -> ThemePalette {
        let accent = NSColor.controlAccentColor
        // Read at draw time, so selection follows a system accent change.
        return ThemePalette(hex: values, accent: accent, accentText: accent, onAccent: .white,
                            selection: rgb(values[0]).blended(withFraction: 0.15, of: accent)!, secondaryAccent: accent)
    }

    var dynamicPalette: ThemePalette {
        // Native views resolve these colors against their own appearance when
        // drawing, so a system day/night change never leaves a captured palette.
        func color(_ keyPath: KeyPath<ThemePalette, NSColor>) -> NSColor {
            NSColor(name: nil) { appearance in
                palette(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)[keyPath: keyPath]
            }
        }
        return ThemePalette(
            background: color(\.background), surface: color(\.surface),
            canvas: color(\.canvas), elevated: color(\.elevated),
            text: color(\.text), secondary: color(\.secondary),
            separator: color(\.separator), accent: color(\.accent), accentText: color(\.accentText), onAccent: color(\.onAccent),
            selection: color(\.selection), secondaryAccent: color(\.secondaryAccent),
            warning: color(\.warning), error: color(\.error)
        )
    }
}

private func rgb(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

private extension ThemePalette {
    /// `values`: background, surface, canvas, elevated, text, secondary, separator, warning, error.
    init(hex values: [UInt32], accent: NSColor, accentText: NSColor, onAccent: NSColor, selection: NSColor, secondaryAccent: NSColor) {
        let color = values.map(rgb)
        self.init(background: color[0], surface: color[1], canvas: color[2],
                  elevated: color[3], text: color[4], secondary: color[5],
                  separator: color[6], accent: accent, accentText: accentText, onAccent: onAccent,
                  selection: selection, secondaryAccent: secondaryAccent, warning: color[7], error: color[8])
    }
}

extension Notification.Name {
    static let rimvaThemeChanged = Notification.Name("rimvaThemeChanged")
}
