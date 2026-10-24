import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RimvaCore

final class BackgroundImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        folder = project.appendingPathComponent(".tmp/background-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testPresetCatalogContainsTwelveDistinctBackgrounds() throws {
        XCTAssertEqual(BackgroundPreset.allCases.count, 12)
        XCTAssertEqual(Set(BackgroundPreset.allCases.map(\.id)).count, 12)
        XCTAssertEqual(Set(BackgroundPreset.allCases.map(\.imageURL)).count, 12)
        for preset in BackgroundPreset.allCases {
            XCTAssertEqual(try JSONDecoder().decode(BackgroundPreset.self, from: JSONEncoder().encode(preset)), preset)
            XCTAssertNotNil(BackgroundImages.thumbnail(url: preset.imageURL), preset.id)
            let output = try render(style: BackgroundStyle(preset: preset, padding: 2, rounded: false, shadow: .off))
            let reference = try render(style: imageStyle(light: preset.imageURL.path))
            XCTAssertEqual(output.dataProvider?.data as Data?, reference.dataProvider?.data as Data?, preset.id)
        }
    }

    func testExistingSavedStyleKeepsPreset() throws {
        let data = Data(#"{"enabled":true,"preset":"鸢尾","padding":48,"rounded":true,"radius":16,"shadow":"light"}"#.utf8)
        let style = try JSONDecoder().decode(BackgroundStyle.self, from: data)
        XCTAssertEqual(style, BackgroundStyle())
        XCTAssertEqual(style.source, .preset)
        XCTAssertTrue(style.followsAppearance)
    }

    func testImageStyleRoundTrip() throws {
        let original = BackgroundStyle(source: .image, lightImagePath: "/day.heic", darkImagePath: "/night.heic", followsAppearance: false)
        let restored = try JSONDecoder().decode(BackgroundStyle.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
    }

    func testImageBackgroundUsesCenteredAspectFill() throws {
        let background = try fixture(width: 12, height: 6) { x, _ in
            x < 4 ? [255, 0, 0, 255] : x < 8 ? [0, 255, 0, 255] : [0, 0, 255, 255]
        }
        let path = try save(background, name: "wide.png").path
        let output = try render(style: imageStyle(light: path))
        XCTAssertEqual(output.width, 6)
        XCTAssertEqual(output.height, 6)
        XCTAssertEqual(pixel(output, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, x: 1, y: 0), [0, 255, 0, 255])
        XCTAssertEqual(pixel(output, x: 5, y: 0), [0, 0, 255, 255])
    }

    func testImageBackgroundKeepsTopLeftOrientation() throws {
        let background = try fixture(width: 6, height: 6) { _, y in y < 3 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let output = try render(style: imageStyle(light: try save(background, name: "vertical.png").path))
        XCTAssertEqual(pixel(output, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, x: 0, y: 5), [0, 0, 255, 255])
    }

    func testDayNightSelectionAndFixedAppearance() throws {
        let day = try save(fixture(width: 6, height: 6) { _, _ in [255, 0, 0, 255] }, name: "day.png").path
        let night = try save(fixture(width: 6, height: 6) { _, _ in [0, 0, 255, 255] }, name: "night.png").path
        var style = imageStyle(light: day, dark: night)
        XCTAssertEqual(pixel(try render(style: style, appearance: .light), x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(try render(style: style, appearance: .dark), x: 0, y: 0), [0, 0, 255, 255])
        style.followsAppearance = false
        XCTAssertEqual(pixel(try render(style: style, appearance: .dark), x: 0, y: 0), [255, 0, 0, 255])
        style.lightImagePath = nil
        XCTAssertEqual(pixel(try render(style: style), x: 0, y: 0), [0, 0, 255, 255])
    }

    func testMissingOrInvalidChosenImageReportsError() throws {
        XCTAssertThrowsError(try render(style: imageStyle(light: nil)))
        XCTAssertThrowsError(try render(style: imageStyle(light: folder.appendingPathComponent("missing.png").path)))
        let invalid = folder.appendingPathComponent("invalid.png")
        try Data("invalid image".utf8).write(to: invalid)
        XCTAssertThrowsError(try render(style: imageStyle(light: invalid.path)))
        let day = try save(fixture(width: 6, height: 6) { _, _ in [255, 0, 0, 255] }, name: "day.png").path
        XCTAssertThrowsError(try render(style: imageStyle(light: day, dark: invalid.path), appearance: .dark))
    }

    func testTransparentBackgroundPreservesAlpha() throws {
        let path = try save(fixture(width: 6, height: 6) { _, _ in [0, 0, 0, 0] }, name: "alpha.png").path
        XCTAssertEqual(pixel(try render(style: imageStyle(light: path)), x: 0, y: 0), [0, 0, 0, 0])
    }

    private func imageStyle(light: String?, dark: String? = nil) -> BackgroundStyle {
        BackgroundStyle(padding: 2, rounded: false, shadow: .off, source: .image, lightImagePath: light, darkImagePath: dark)
    }

    private func render(style: BackgroundStyle, appearance: RenderAppearance = .light) throws -> CGImage {
        let source = try fixture(width: 2, height: 2) { _, _ in [0, 0, 0, 0] }
        return try ImageRenderer.render(image: source, state: EditState(), style: style, appearance: appearance)
    }

    private func save(_ image: CGImage, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func fixture(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        let data = Data((0..<height).flatMap { y in (0..<width).flatMap { x in pixel(x, y) } })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }
}
