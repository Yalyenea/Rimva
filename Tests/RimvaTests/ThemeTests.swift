import AppKit
import XCTest
@testable import Rimva

final class ThemeTests: XCTestCase {
    func testRosePineUsesMutedGrayVioletAccents() throws {
        for dark in [false, true] {
            let palette = AppTheme.rosePine.palette(dark: dark)
            for color in [palette.accent, palette.accentText, palette.secondaryAccent] {
                let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
                let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                XCTAssertLessThanOrEqual(components.max()! - components.min()!, 0.17)
                XCTAssertGreaterThanOrEqual(rgb.blueComponent, rgb.redComponent)
                XCTAssertGreaterThanOrEqual(rgb.blueComponent, rgb.greenComponent)
            }
        }
    }

    func testRosePineActiveLabelsRemainReadable() throws {
        func luminance(_ color: NSColor) throws -> CGFloat {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        for dark in [false, true] {
            let palette = AppTheme.rosePine.palette(dark: dark)
            for (foreground, background) in [(palette.accentText, palette.selection), (palette.onAccent, palette.accent)] {
                let values = try [luminance(foreground), luminance(background)]
                XCTAssertGreaterThanOrEqual((values.max()! + 0.05) / (values.min()! + 0.05), 4.5)
            }
        }
    }
}
