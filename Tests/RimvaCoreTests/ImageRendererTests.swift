import AppKit
import XCTest
@testable import RimvaCore

final class ImageRendererTests: XCTestCase {
    func testCropUsesOriginalTopLeftPixelCoordinates() throws {
        let source = try fixture(width: 8, height: 6) { _, y in y < 3 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let state = EditState(crop: CGRect(x: 2, y: 1, width: 4, height: 4))
        let output = try ImageRenderer.render(image: source, state: state, style: BackgroundStyle(enabled: false, rounded: false))

        XCTAssertEqual(output.width, 4)
        XCTAssertEqual(output.height, 4)
        XCTAssertEqual(pixel(output, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, x: 3, y: 3), [0, 0, 255, 255])
    }

    func testCropKeepsAnnotationCoordinatesInOriginalImage() throws {
        let source = try fixture(width: 8, height: 6) { _, y in y < 3 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let mark = Annotation(kind: .redact, start: CGPoint(x: 3, y: 2), end: CGPoint(x: 5, y: 4), colorHex: "#00FF00")
        let state = EditState(crop: CGRect(x: 2, y: 1, width: 4, height: 4), annotations: [mark])
        let output = try ImageRenderer.render(image: source, state: state, style: BackgroundStyle(enabled: false, rounded: false))

        XCTAssertEqual(pixel(output, x: 1, y: 1), [0, 255, 0, 255])
        XCTAssertEqual(pixel(output, x: 0, y: 1), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, x: 1, y: 3), [0, 0, 255, 255])
    }

    func testRedactionCoversWholePixelsWithOpaqueColor() throws {
        let source = try fixture(width: 8, height: 8) { _, _ in [255, 255, 255, 255] }
        let mark = Annotation(kind: .redact, start: CGPoint(x: 1.3, y: 2.8), end: CGPoint(x: 4.2, y: 5.1), colorHex: "#000000")
        let output = try ImageRenderer.render(image: source, state: EditState(annotations: [mark]), style: BackgroundStyle(enabled: false, rounded: false))

        for y in 2..<6 {
            for x in 1..<5 {
                XCTAssertEqual(pixel(output, x: x, y: y), [0, 0, 0, 255])
            }
        }
        XCTAssertEqual(pixel(output, x: 0, y: 3), [255, 255, 255, 255])
    }

    func testAnnotationsAreClippedBeforeBackgroundComposition() throws {
        let source = try fixture(width: 8, height: 6) { _, _ in [255, 0, 0, 255] }
        let mark = Annotation(kind: .redact, start: .zero, end: CGPoint(x: 8, y: 6), colorHex: "#00FF00")
        let state = EditState(crop: CGRect(x: 2, y: 1, width: 4, height: 4), annotations: [mark])
        let style = BackgroundStyle(customHex: "#FFFFFF", padding: 3, rounded: false, shadow: .off)
        let output = try ImageRenderer.render(image: source, state: state, style: style)

        XCTAssertEqual(CGSize(width: output.width, height: output.height), CGSize(width: 10, height: 10))
        XCTAssertEqual(pixel(output, x: 3, y: 3), [0, 255, 0, 255])
        XCTAssertEqual(pixel(output, x: 2, y: 3), [255, 255, 255, 255])
        XCTAssertEqual(pixel(output, x: 7, y: 3), [255, 255, 255, 255])
    }

    func testRoundedCornersAndDisabledBackground() throws {
        let source = try fixture(width: 20, height: 20) { _, _ in [255, 0, 0, 255] }
        var style = BackgroundStyle(customHex: "#FFFFFF", padding: 4, rounded: true, radius: 8, shadow: .off)
        let rounded = try ImageRenderer.render(image: source, state: EditState(), style: style)
        XCTAssertEqual(rounded.width, 28)
        XCTAssertEqual(pixel(rounded, x: 4, y: 4), [255, 255, 255, 255])
        XCTAssertEqual(pixel(rounded, x: 14, y: 4), [255, 0, 0, 255])

        style.enabled = false
        style.shadow = .standard
        let plain = try ImageRenderer.render(image: source, state: EditState(), style: style)
        XCTAssertEqual(plain.width, 20)
        XCTAssertEqual(plain.height, 20)
        XCTAssertEqual(pixel(plain, x: 0, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(plain, x: 10, y: 0), [255, 0, 0, 255])

        style.rounded = false
        let square = try ImageRenderer.render(image: source, state: EditState(), style: style)
        XCTAssertEqual(pixel(square, x: 0, y: 0), [255, 0, 0, 255])
    }

    func testRoundedCropWithoutBackgroundClipsAnnotationsAtTransparentCorners() throws {
        let source = try fixture(width: 80, height: 70) { _, _ in [255, 0, 0, 255] }
        let mark = Annotation(kind: .redact, start: .zero, end: CGPoint(x: 80, y: 70), colorHex: "#00FF00")
        let state = EditState(crop: CGRect(x: 10, y: 15, width: 40, height: 30), annotations: [mark])
        let style = BackgroundStyle(enabled: false, padding: 160, radius: 40, shadow: .standard)
        let output = try ImageRenderer.render(image: source, state: state, style: style)

        XCTAssertEqual(ImageRenderer.contentRect(image: source, state: state, style: style), CGRect(x: 0, y: 0, width: 40, height: 30))
        XCTAssertEqual(CGSize(width: output.width, height: output.height), CGSize(width: 40, height: 30))
        for (x, y) in [(0, 0), (39, 0), (0, 29), (39, 29)] {
            XCTAssertEqual(pixel(output, x: x, y: y), [0, 0, 0, 0])
        }
        XCTAssertEqual(pixel(output, x: 20, y: 15), [0, 255, 0, 255])
        // A rounded redaction must not leave source color at partially transparent edges.
        for y in 0..<15 {
            for x in 0..<15 { XCTAssertEqual(pixel(output, x: x, y: y)[0], 0) }
        }
    }

    func testRoundingWithoutBackgroundRejectsInvalidRadiusAndAllowsZero() throws {
        let source = try fixture(width: 20, height: 20) { _, _ in [255, 0, 0, 255] }
        for radius in [Double.nan, .infinity, -1] {
            XCTAssertThrowsError(try ImageRenderer.render(image: source, state: EditState(), style: BackgroundStyle(enabled: false, radius: radius))) {
                guard case ImageRenderingError.invalidStyle = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        let output = try ImageRenderer.render(image: source, state: EditState(), style: BackgroundStyle(enabled: false, radius: 0))
        XCTAssertEqual(pixel(output, x: 0, y: 0), [255, 0, 0, 255])
    }

    func testShadowGetsSpaceAndFallsBelowImage() throws {
        let source = try fixture(width: 40, height: 40) { _, _ in [255, 255, 255, 255] }
        let style = BackgroundStyle(customHex: "#FFFFFF", padding: 0, rounded: false, shadow: .standard)
        let rect = ImageRenderer.contentRect(image: source, state: EditState(), style: style)
        let output = try ImageRenderer.render(image: source, state: EditState(), style: style)

        XCTAssertEqual(output.width, Int(ImageRenderer.outputSize(image: source, state: EditState(), style: style).width))
        XCTAssertGreaterThan(rect.minX, 40)
        XCTAssertEqual(pixel(output, x: 0, y: output.height / 2), [255, 255, 255, 255])
        let above = pixel(output, x: Int(rect.midX), y: Int(rect.minY) - 8)[0]
        let below = pixel(output, x: Int(rect.midX), y: Int(rect.maxY) + 8)[0]
        XCTAssertLessThan(below, above)
    }

    func testNativeChineseTextDrawsBothLines() throws {
        let source = try fixture(width: 180, height: 100) { _, _ in [255, 255, 255, 255] }
        let mark = Annotation(kind: .text, start: CGPoint(x: 10, y: 5), end: CGPoint(x: 170, y: 95), text: "中文第一行\n第二行", colorHex: "#000000", fontSize: 24)
        let output = try ImageRenderer.render(image: source, state: EditState(annotations: [mark]), style: BackgroundStyle(enabled: false, rounded: false))

        let firstLine = (5..<35).contains { y in (10..<170).contains { x in pixel(output, x: x, y: y)[0] < 100 } }
        let secondLine = (35..<70).contains { y in (10..<170).contains { x in pixel(output, x: x, y: y)[0] < 100 } }
        XCTAssertTrue(firstLine)
        XCTAssertTrue(secondLine)
    }

    func testTransparentImageDoesNotRevealBlackShadowCaster() throws {
        let source = try fixture(width: 20, height: 20) { _, _ in [0, 0, 0, 0] }
        let style = BackgroundStyle(customHex: "#FFFFFF", padding: 0, rounded: false, shadow: .light)
        let content = ImageRenderer.contentRect(image: source, state: EditState(), style: style)
        let output = try ImageRenderer.render(image: source, state: EditState(), style: style)
        XCTAssertEqual(pixel(output, x: Int(content.midX), y: Int(content.midY)), [255, 255, 255, 255])
    }

    func testRedactionDoesNotLeakSourceThroughAntialiasedRoundedEdge() throws {
        let source = try fixture(width: 20, height: 20) { _, _ in [255, 0, 0, 255] }
        let mark = Annotation(kind: .redact, start: .zero, end: CGPoint(x: 20, y: 20), colorHex: "#000000")
        let style = BackgroundStyle(customHex: "#FFFFFF", padding: 4, radius: 8, shadow: .off)
        let output = try ImageRenderer.render(image: source, state: EditState(annotations: [mark]), style: style)
        for y in 4..<12 {
            for x in 4..<12 {
                let value = pixel(output, x: x, y: y)
                XCTAssertEqual(value[0], value[1], "Source red must not survive in the rounded boundary at \(x), \(y)")
            }
        }
    }

    func testInvalidOrOversizedLayoutFailsBeforeAllocation() throws {
        let source = try fixture(width: 8, height: 8) { _, _ in [255, 0, 0, 255] }
        XCTAssertThrowsError(try ImageRenderer.render(image: source, state: EditState(crop: CGRect(x: 99, y: 99, width: 8, height: 8)), style: BackgroundStyle()))
        XCTAssertThrowsError(try ImageRenderer.render(image: source, state: EditState(), style: BackgroundStyle(padding: .greatestFiniteMagnitude)))
        XCTAssertThrowsError(try ImageRenderer.render(image: source, state: EditState(), style: BackgroundStyle(customHex: "#11223300")))
    }

    private func fixture(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        let data = Data((0..<height).flatMap { y in (0..<width).flatMap { x in pixel(x, y) } })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }
}
