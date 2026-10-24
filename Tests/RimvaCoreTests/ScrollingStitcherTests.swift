import AppKit
import XCTest
@testable import RimvaCore

final class ScrollingStitcherTests: XCTestCase {
    func testExactOverlapAddsOnlyNewNativeRows() throws {
        var stitcher = try ScrollingStitcher(first: capture(offset: 0))
        XCTAssertEqual(try stitcher.append(capture(offset: 28)), .appended(pixels: 28))
        XCTAssertEqual(stitcher.width, 64)
        XCTAssertEqual(stitcher.height, 124)
        XCTAssertEqual(stitcher.frameCount, 2)
        try assertDocument(stitcher.image(), offset: 0)
    }

    func testSeveralScrollsHaveNoRepeatedOrMissingRows() throws {
        var stitcher = try ScrollingStitcher(first: capture(offset: 0))
        for (offset, distance) in [(17, 17), (43, 26), (82, 39)] {
            XCTAssertEqual(try stitcher.append(capture(offset: offset)), .appended(pixels: distance))
        }
        XCTAssertEqual(stitcher.height, 178)
        XCTAssertEqual(stitcher.frameCount, 4)
        try assertDocument(stitcher.image(), offset: 0)
    }

    func testOutputKeepsTopLeftOrientation() throws {
        func frame(_ offset: Int) throws -> CGImage {
            try fixture(width: 64, height: 96) { x, y in
                if offset + y == 0 { return [255, 0, 0, 255] }
                if offset + y == 155 { return [0, 0, 255, 255] }
                return documentPixel(x, offset + y)
            }
        }
        var stitcher = try ScrollingStitcher(first: frame(0))
        XCTAssertEqual(try stitcher.append(frame(60)), .appended(pixels: 60))
        let output = try stitcher.image()
        XCTAssertEqual(pixel(output, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, x: 0, y: 155), [0, 0, 255, 255])
        XCTAssertEqual(pixel(output, x: 12, y: 80), documentPixel(12, 80))
    }

    func testDuplicateFrameDoesNotChangeImageOrCount() throws {
        let first = try capture(offset: 0)
        var stitcher = try ScrollingStitcher(first: first)
        XCTAssertEqual(try stitcher.append(first), .unchanged)
        XCTAssertEqual(stitcher.height, 96)
        XCTAssertEqual(stitcher.frameCount, 1)
        try assertDocument(stitcher.image(), offset: 0)
    }

    func testUpwardAndUnrelatedFramesPreserveLastAcceptedReference() throws {
        var stitcher = try ScrollingStitcher(first: capture(offset: 100))
        XCTAssertEqual(try stitcher.append(capture(offset: 80)), .noOverlap)
        XCTAssertEqual(try stitcher.append(capture(offset: 500)), .noOverlap)
        XCTAssertEqual(stitcher.height, 96)
        XCTAssertEqual(stitcher.frameCount, 1)
        XCTAssertEqual(try stitcher.append(capture(offset: 124)), .appended(pixels: 24))
        try assertDocument(stitcher.image(), offset: 100)
    }

    func testPeriodicRowsAreRejectedAsAmbiguous() throws {
        func frame(_ offset: Int) throws -> CGImage {
            try fixture(width: 64, height: 96) { x, y in documentPixel(x, (y + offset) % 24) }
        }
        var stitcher = try ScrollingStitcher(first: frame(0))
        XCTAssertEqual(try stitcher.append(frame(8)), .noOverlap)
        XCTAssertEqual(stitcher.height, 96)
        XCTAssertEqual(stitcher.frameCount, 1)
    }

    func testBlankFramesCannotInventScrollOrHideSparseContentChanges() throws {
        let blank = try fixture(width: 64, height: 96) { _, _ in [255, 255, 255, 255] }
        let darker = try fixture(width: 64, height: 96) { _, _ in [250, 250, 250, 255] }
        var stitcher = try ScrollingStitcher(first: blank)
        XCTAssertEqual(try stitcher.append(blank), .unchanged)
        XCTAssertFalse(ScrollingStitcher.framesMatch(blank, darker))
        XCTAssertEqual(try stitcher.append(darker), .noOverlap)

        func sparse(_ row: Int) throws -> CGImage {
            try fixture(width: 64, height: 96) { x, y in
                x >= 10 && x < 14 && y >= row && y < row + 4 ? [0, 0, 0, 255] : [255, 255, 255, 255]
            }
        }
        let first = try sparse(40)
        let second = try sparse(20)
        XCTAssertFalse(ScrollingStitcher.framesMatch(first, second))
        var sparseStitcher = try ScrollingStitcher(first: first)
        XCTAssertEqual(try sparseStitcher.append(second), .noOverlap)
        XCTAssertEqual(sparseStitcher.frameCount, 1)
    }

    func testSmallNoiseAndCursorChangesStillMatchDetailedContent() throws {
        let first = try capture(offset: 0, width: 96)
        let noise = try fixture(width: 96, height: 96) { x, y in
            var value = documentPixel(x, y)
            if (x + y * 96) % 101 == 0 { value[0] = value[0] < 253 ? value[0] + 2 : value[0] - 2 }
            return value
        }
        XCTAssertTrue(ScrollingStitcher.framesMatch(first, noise))
        let cursor = try fixture(width: 96, height: 96) { x, y in
            x >= 6 && x < 10 && y >= 20 && y < 24 ? [0, 0, 0, 255] : documentPixel(x, y)
        }
        XCTAssertTrue(ScrollingStitcher.framesMatch(first, cursor))
        let scrolled = try fixture(width: 96, height: 96) { x, y in
            var value = documentPixel(x, y + 23)
            if (x + y * 96) % 101 == 0 { value[0] = value[0] < 253 ? value[0] + 2 : value[0] - 2 }
            if x >= 6 && x < 10 && y >= 20 && y < 24 { return [0, 0, 0, 255] }
            return value
        }
        var stitcher = try ScrollingStitcher(first: first)
        XCTAssertEqual(try stitcher.append(scrolled), .appended(pixels: 23))
        let output = try stitcher.image()
        XCTAssertEqual(pixel(output, x: 50, y: 118), documentPixel(50, 118))
    }

    func testStationaryHeaderAndFooterAppearOnlyAtOuterEdges() throws {
        let header = 8
        let footer = 10
        func headerPixel(_ x: Int, _ y: Int) -> [UInt8] { [UInt8(20 + x), UInt8(30 + y), 80, 255] }
        func footerPixel(_ x: Int, _ y: Int) -> [UInt8] { [180, UInt8(80 + x), UInt8(20 + y), 255] }
        func frame(_ offset: Int) throws -> CGImage {
            try fixture(width: 64, height: 96) { x, y in
                if y < header { return headerPixel(x, y) }
                if y >= 96 - footer { return footerPixel(x, y - (96 - footer)) }
                return documentPixel(x, offset + y - header)
            }
        }
        var stitcher = try ScrollingStitcher(first: frame(0))
        XCTAssertEqual(try stitcher.append(frame(25)), .appended(pixels: 25))
        XCTAssertEqual(try stitcher.append(frame(60)), .appended(pixels: 35))
        let output = try stitcher.image()
        XCTAssertEqual(output.height, 156)
        for y in 0..<output.height {
            for x in 0..<output.width {
                let expected = y < header ? headerPixel(x, y)
                    : y >= output.height - footer ? footerPixel(x, y - (output.height - footer))
                    : documentPixel(x, y - header)
                XCTAssertEqual(pixel(output, x: x, y: y), expected, "Unexpected pixel at \(x), \(y)")
            }
        }
    }

    func testBGRAInputIsNormalizedBeforeMatchingAndExport() throws {
        let first = try fixture(width: 64, height: 96, bgra: true) { x, y in documentPixel(x, y) }
        var stitcher = try ScrollingStitcher(first: first)
        XCTAssertEqual(try stitcher.append(capture(offset: 30)), .appended(pixels: 30))
        try assertDocument(stitcher.image(), offset: 0)
    }

    func testWhiteMarginsAndTextLikeRowsKeepTheirOriginalSpacing() throws {
        func pagePixel(_ x: Int, _ y: Int) -> [UInt8] {
            guard x >= 60, x < 580, y % 24 < 10, (x - 60) % 8 < 6 else { return [255, 255, 255, 255] }
            let character = (x - 60) / 8
            let value = UInt32(y / 24 + 1) &* 0x85EB_CA77 ^ UInt32(character + 1) &* 0x9E37_79B1
            let ink = (value >> (((x - 60) % 8 + (y % 24) * 3) % 24)) & 1 == 1
            return ink ? [30, 30, 30, 255] : [255, 255, 255, 255]
        }
        let first = try fixture(width: 640, height: 240, pixel: pagePixel)
        let next = try fixture(width: 640, height: 240) { x, y in pagePixel(x, y + 83) }
        var stitcher = try ScrollingStitcher(first: first)
        XCTAssertEqual(try stitcher.append(next), .appended(pixels: 83))
        let output = try stitcher.image()
        let expected = try fixture(width: 640, height: 323, pixel: pagePixel)
        XCTAssertEqual(output.height, 323)
        XCTAssertEqual(output.dataProvider!.data! as Data, expected.dataProvider!.data! as Data)
    }

    func testDimensionErrorsAndLengthLimitPreserveContent() throws {
        var stitcher = try ScrollingStitcher(first: capture(offset: 0))
        XCTAssertThrowsError(try stitcher.append(capture(offset: 20, width: 63)))
        XCTAssertThrowsError(try ScrollingStitcher(first: capture(offset: 0, width: 16_001, height: 1)))
        XCTAssertThrowsError(try ScrollingStitcher(first: capture(offset: 0, width: 1, height: 30_001)))
        let widest = try ScrollingStitcher(first: capture(offset: 0, width: 16_000, height: 1))
        XCTAssertEqual(widest.width, 16_000)
        XCTAssertEqual(stitcher.frameCount, 1)
        try assertDocument(stitcher.image(), offset: 0)

        var full = try ScrollingStitcher(first: capture(offset: 0, width: 2, height: 30_000))
        XCTAssertEqual(try full.append(capture(offset: 12, width: 2, height: 30_000)), .limitReached)
        XCTAssertEqual(full.height, 30_000)
        XCTAssertEqual(full.frameCount, 1)
        let output = try full.image()
        XCTAssertEqual(pixel(output, x: 1, y: 29_999), documentPixel(1, 29_999))
    }

    private func capture(offset: Int, width: Int = 64, height: Int = 96) throws -> CGImage {
        try fixture(width: width, height: height) { x, y in documentPixel(x, y + offset) }
    }

    private func documentPixel(_ x: Int, _ y: Int) -> [UInt8] {
        // Coordinate-derived texture gives every document row a stable identity.
        var value = UInt32(x) &* 0x9E37_79B1 &+ UInt32(y) &* 0x85EB_CA77 &+ 17
        value = (value ^ (value >> 16)) &* 0x7FEB_352D
        value = (value ^ (value >> 15)) &* 0x846C_A68B
        value ^= value >> 16
        return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), 255]
    }

    private func assertDocument(_ image: CGImage, offset: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        for y in 0..<image.height {
            for x in 0..<image.width {
                XCTAssertEqual(pixel(image, x: x, y: y), documentPixel(x, offset + y), "Unexpected pixel at \(x), \(y)", file: file, line: line)
            }
        }
    }

    private func fixture(width: Int, height: Int, bgra: Bool = false, pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        let data = Data((0..<height).flatMap { y in
            (0..<width).flatMap { x -> [UInt8] in
                let value = pixel(x, y)
                return bgra ? [value[2], value[1], value[0], value[3]] : value
            }
        })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let format = bgra
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: format,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }
}
