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
    let accent: NSColor
    let onAccent: NSColor
    let selection: NSColor
    let secondaryAccent: NSColor
    let warning: NSColor
    let error: NSColor
}

enum AppTheme: String, CaseIterable, Identifiable {
    case neutral, rosePine, catppuccin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neutral: L("默认")
        case .rosePine: "Rosé Pine"
        case .catppuccin: "Catppuccin"
        }
    }

    func palette(dark: Bool) -> ThemePalette {
        // Keep each theme's original workspace colors. Interface ink and accents
        // use restrained, cool variants, independent of annotation canvas colors.
        switch (self, dark) {
        case (.neutral, false):
            ThemePalette(hex: [0xF3F4F6, 0xF3F4F6, 0xFAFBFC, 0xE8EAED, 0x343941, 0x60666E, 0xD5D9DE, 0x596675, 0xF8FAFC, 0xE3E7EB, 0x596675, 0x966F37, 0xA55E67])
        case (.neutral, true):
            ThemePalette(hex: [0x20222B, 0x20222B, 0x272A35, 0x2E323A, 0xE1E4E8, 0xA1A8B1, 0x3D424B, 0xA2ADB9, 0x222730, 0x363D47, 0xA2ADB9, 0xC7AB7C, 0xCC929A])
        case (.rosePine, false):
            ThemePalette(hex: [0xFAF4ED, 0xFAF4ED, 0xFFFAF3, 0xEAE8E5, 0x3E3E48, 0x63636E, 0xDBD8D6, 0x626576, 0xF9F8FA, 0xE5E4E8, 0x626576, 0x987440, 0xA76270])
        case (.rosePine, true):
            ThemePalette(hex: [0x191724, 0x191724, 0x1F1D2E, 0x292835, 0xE2E0E7, 0xA6A2B0, 0x3F3C4A, 0xA8A6B6, 0x22212C, 0x35323F, 0xA8A6B6, 0xC5AA80, 0xCC919F])
        case (.catppuccin, false):
            ThemePalette(hex: [0xEFF1F5, 0xEFF1F5, 0xE6E9EF, 0xE1E5EA, 0x3E4450, 0x5D6572, 0xCFD4DD, 0x5F6B7D, 0xF9FAFC, 0xDDE3EB, 0x5F6B7D, 0x94733E, 0xA15F70])
        case (.catppuccin, true):
            ThemePalette(hex: [0x1E1E2E, 0x1E1E2E, 0x181825, 0x2B2D3B, 0xDFE3EC, 0xA3ABBC, 0x3D4253, 0xA5AFC4, 0x232632, 0x343B4D, 0xA5AFC4, 0xC5B087, 0xCD94A3])
        }
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
            separator: color(\.separator), accent: color(\.accent), onAccent: color(\.onAccent),
            selection: color(\.selection), secondaryAccent: color(\.secondaryAccent),
            warning: color(\.warning), error: color(\.error)
        )
    }
}

private extension ThemePalette {
    init(hex values: [UInt32]) {
        func color(_ index: Int) -> NSColor {
            let value = values[index]
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        self.init(background: color(0), surface: color(1), canvas: color(2),
                  elevated: color(3), text: color(4), secondary: color(5),
                  separator: color(6), accent: color(7), onAccent: color(8),
                  selection: color(9), secondaryAccent: color(10), warning: color(11), error: color(12))
    }
}

extension Notification.Name {
    static let rimvaThemeChanged = Notification.Name("rimvaThemeChanged")
}
