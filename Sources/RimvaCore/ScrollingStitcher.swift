import CoreGraphics
import Foundation

public enum ScrollingAppendResult: Equatable {
    case appended(pixels: Int)
    case unchanged
    case noOverlap
    case limitReached
}

public enum ScrollingStitchingError: LocalizedError {
    case invalidDimensions
    case mismatchedDimensions
    case imageTooLarge
    case allocationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions: L("长截图的选区尺寸无效。")
        case .mismatchedDimensions: L("截图尺寸发生变化，请重新开始长截图。")
        case .imageTooLarge: L("长截图已达到尺寸上限，请缩小选区。")
        case .allocationFailed: L("无法生成长截图，内存可能不足。")
        }
    }
}

/// Accepts stationary frames from a manually scrolled, fixed-size capture region.
public struct ScrollingStitcher {
    public let width: Int
    public private(set) var height: Int
    public private(set) var frameCount: Int = 1

    private static let maximumWidth = 16_000
    private static let maximumHeight = 30_000
    private static let maximumPixels = 80_000_000
    private var previous: Raster
    private var strips: [Strip]

    public init(first: CGImage) throws {
        try Self.validate(first)
        let raster = try Raster(first)
        width = first.width
        height = first.height
        previous = raster
        strips = [Strip(bytes: raster.bytes, height: first.height)]
    }

    public mutating func append(_ frame: CGImage) throws -> ScrollingAppendResult {
        guard frame.width == width, frame.height == previous.height else {
            throw ScrollingStitchingError.mismatchedDimensions
        }
        var next = try Raster(frame)
        if Self.equivalent(previous, next) { return .unchanged }
        guard height < Self.maximumHeight, height < Self.maximumPixels / width else { return .limitReached }
        // Stable-frame polling needs no search summaries. Build them only for
        // overlap detection, then retain the accepted frame's summary.
        previous.prepareSamples()
        next.prepareSamples()
        guard let match = Self.overlap(previous, next), match.offset > 0 else { return .noOverlap }
        guard match.offset <= Self.maximumHeight - height,
              match.offset <= Self.maximumPixels / width - height else { return .limitReached }

        // Replace the stationary footer so it appears only at the final bottom edge.
        // All allocations finish before the accepted image or reference frame changes.
        let start = next.height - match.footer - match.offset
        let addition = try Self.copyRows(next.bytes, start: start, count: match.offset + match.footer, width: width)
        var updated = strips
        var remaining = match.footer
        while remaining > 0, let last = updated.popLast() {
            if last.height > remaining {
                let kept = last.height - remaining
                updated.append(Strip(bytes: try Self.copyRows(last.bytes, start: 0, count: kept, width: width), height: kept))
                remaining = 0
            } else {
                remaining -= last.height
            }
        }
        updated.append(Strip(bytes: addition, height: match.offset + match.footer))
        strips = updated
        previous = next
        height += match.offset
        frameCount += 1
        return .appended(pixels: match.offset)
    }

    public func image() throws -> CGImage {
        let count = width * height * 4
        guard let memory = malloc(count) else { throw ScrollingStitchingError.allocationFailed }
        var offset = 0
        for strip in strips {
            strip.bytes.withUnsafeBytes { bytes in
                _ = memcpy(memory.advanced(by: offset), bytes.baseAddress!, bytes.count)
            }
            offset += strip.bytes.count
        }
        let data = Data(bytesNoCopy: memory, count: count, deallocator: .free)
        guard let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: Self.colorSpace, bitmapInfo: Self.bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw ScrollingStitchingError.allocationFailed }
        return result
    }

    /// Visible changes must reach overlap detection: a small text change and a
    /// cursor have no reliable distinction in captured pixels alone.
    public static func framesMatch(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              (try? validate(a)) != nil,
              let first = try? Raster(a), let second = try? Raster(b) else { return false }
        return equivalent(first, second)
    }

    private struct Strip {
        var bytes: Data
        var height: Int
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: Data
        let sampleWidth: Int
        var samples: [UInt8] = []

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            let byteCount = width * height * 4
            guard let memory = malloc(byteCount) else { throw ScrollingStitchingError.allocationFailed }
            guard let context = CGContext(
                data: memory, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: ScrollingStitcher.colorSpace, bitmapInfo: ScrollingStitcher.bitmapInfo.rawValue
            ) else {
                free(memory)
                throw ScrollingStitchingError.allocationFailed
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            // CGImage rows and this untransformed bitmap context both start at the
            // image's top edge. No AppKit coordinate transform participates here.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.flush()
            bytes = Data(bytesNoCopy: memory, count: byteCount, deallocator: .free)
            sampleWidth = min(width, 64)
        }

        mutating func prepareSamples() {
            guard samples.isEmpty else { return }
            samples = bytes.withUnsafeBytes { raw in
                var sampled = [UInt8](repeating: 0, count: sampleWidth * height * 12)
                let source = raw.bindMemory(to: UInt8.self).baseAddress!
                for y in 0..<height {
                    for x in 0..<sampleWidth {
                        let start = x * width / sampleWidth
                        let end = (x + 1) * width / sampleWidth
                        let target = (y * sampleWidth + x) * 12
                        // Every source column contributes. Point sampling can miss
                        // a narrow text column or a scrollbar completely.
                        for channel in 0..<4 {
                            var minimum: UInt8 = 255
                            var maximum: UInt8 = 0
                            var sum = 0
                            for sourceX in start..<end {
                                let value = source[(y * width + sourceX) * 4 + channel]
                                minimum = min(minimum, value)
                                maximum = max(maximum, value)
                                sum += Int(value)
                            }
                            sampled[target + channel] = minimum
                            sampled[target + 4 + channel] = maximum
                            sampled[target + 8 + channel] = UInt8(sum / (end - start))
                        }
                    }
                }
                return sampled
            }
        }
    }

    private struct Match {
        let offset: Int
        let footer: Int
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

    private static func validate(_ image: CGImage) throws {
        guard image.width > 0, image.height > 0 else { throw ScrollingStitchingError.invalidDimensions }
        guard image.width <= maximumWidth, image.height <= maximumHeight,
              image.height <= maximumPixels / image.width else { throw ScrollingStitchingError.imageTooLarge }
    }

    private static func copyRows(_ data: Data, start: Int, count: Int, width: Int) throws -> Data {
        let byteCount = count * width * 4
        guard let memory = malloc(byteCount) else { throw ScrollingStitchingError.allocationFailed }
        data.withUnsafeBytes { bytes in
            _ = memcpy(memory, bytes.baseAddress!.advanced(by: start * width * 4), byteCount)
        }
        return Data(bytesNoCopy: memory, count: byteCount, deallocator: .free)
    }

    @inline(__always)
    private static func delta(_ a: UnsafePointer<UInt8>, _ ai: Int, _ b: UnsafePointer<UInt8>, _ bi: Int) -> Int {
        max(abs(Int(a[ai]) - Int(b[bi])), abs(Int(a[ai + 1]) - Int(b[bi + 1])),
            abs(Int(a[ai + 2]) - Int(b[bi + 2])), abs(Int(a[ai + 3]) - Int(b[bi + 3])))
    }

    private static func equivalent(_ a: Raster, _ b: Raster) -> Bool {
        if a.bytes == b.bytes { return true }
        let pixelCount = a.width * a.height
        return a.bytes.withUnsafeBytes { first in
            b.bytes.withUnsafeBytes { second in
                let p = first.bindMemory(to: UInt8.self).baseAddress!
                let q = second.bindMemory(to: UInt8.self).baseAddress!
                var bias = [Int64](repeating: 0, count: 4)
                for index in stride(from: 0, to: first.count, by: 4) {
                    guard delta(p, index, q, index) <= 3 else { return false }
                    for channel in 0..<4 { bias[channel] += Int64(p[index + channel]) - Int64(q[index + channel]) }
                }
                // A global color change is a different frame, even on a blank page.
                return bias.allSatisfy { abs($0) * 2 <= Int64(pixelCount) }
            }
        }
    }

    private static func overlap(_ a: Raster, _ b: Raster) -> Match? {
        guard a.height >= 8 else { return nil }
        return a.bytes.withUnsafeBytes { first in
            b.bytes.withUnsafeBytes { second in
                let p = first.bindMemory(to: UInt8.self).baseAddress!
                let q = second.bindMemory(to: UInt8.self).baseAddress!
                func stationary(_ y: Int) -> Bool {
                    for x in 0..<a.width {
                        let index = (y * a.width + x) * 4
                        if delta(p, index, q, index) > 3 { return false }
                    }
                    return true
                }
                var header = 0
                var footer = 0
                // Only uninterrupted stationary edge strips can be treated as
                // chrome. Keeping a large central body prevents blank-page guesses.
                while header < a.height / 3, stationary(header) { header += 1 }
                while footer < a.height / 3, stationary(a.height - 1 - footer) { footer += 1 }
                let bodyHeight = a.height - header - footer
                let minimumOverlap = max(4, bodyHeight / 5)
                guard bodyHeight > minimumOverlap else { return nil }
                var firstDetailedRows = 0
                var secondDetailedRows = 0
                let requiredRows = min(8, minimumOverlap)
                for y in header..<(a.height - footer) {
                    let neighbor = y + 1 < a.height - footer ? a.width * 4 : -a.width * 4
                    var firstDetail = false
                    var secondDetail = false
                    for x in 0..<a.width {
                        let index = (y * a.width + x) * 4
                        firstDetail = firstDetail || delta(p, index, p, index + neighbor) > 12
                            || (x > 0 && delta(p, index, p, index - 4) > 12)
                        secondDetail = secondDetail || delta(q, index, q, index + neighbor) > 12
                            || (x > 0 && delta(q, index, q, index - 4) > 12)
                        if firstDetail && secondDetail { break }
                    }
                    if firstDetail { firstDetailedRows += 1 }
                    if secondDetail { secondDetailedRows += 1 }
                    if firstDetailedRows >= requiredRows && secondDetailedRows >= requiredRows { break }
                }
                // Whitespace alone produces many zero-error shifts. Reject it
                // before spending time validating every possible alignment.
                guard firstDetailedRows >= requiredRows, secondDetailedRows >= requiredRows else { return nil }
                // A fixed sidebar may fall outside the shared rows of a large
                // scroll. Extending it would repeat its icons or text.
                for direction in [1, -1] {
                    for x in stride(from: direction > 0 ? 0 : a.width - 1,
                                    through: direction > 0 ? a.width - 1 : 0, by: direction) {
                        var stationaryColumn = true
                        var verticalDetail = false
                        for y in header..<(a.height - footer) {
                            let index = (y * a.width + x) * 4
                            if delta(p, index, q, index) > 3 {
                                stationaryColumn = false
                                break
                            }
                            if y > header, delta(p, index, p, index - a.width * 4) > 12 { verticalDetail = true }
                        }
                        if !stationaryColumn { break }
                        if verticalDetail { return nil }
                    }
                }
                var acceptedOffset: Int?
                // Short reverse overlaps still expose repeating content. They
                // are considered for ambiguity, even when too short to append.
                for distance in 1...(bodyHeight - 4) {
                    let rows = bodyHeight - distance
                    for direction in [-1, 1] {
                        let startA = header + (direction > 0 ? distance : 0)
                        let startB = header + (direction < 0 ? distance : 0)
                        if coarseOverlapMatches(a, b, startA: startA, startB: startB, rows: rows),
                           nativeOverlapMatches(a, b, startA: startA, startB: startB, rows: rows) {
                            // Check upward alignments too: a periodic page must not turn
                            // an upward scroll into an apparently valid downward one.
                            guard acceptedOffset == nil else { return nil }
                            acceptedOffset = distance * direction
                        }
                    }
                }
                guard let acceptedOffset, acceptedOffset > 0,
                      bodyHeight - acceptedOffset >= minimumOverlap else { return nil }
                // A moving scrollbar thumb can occupy only the unshared middle
                // of both frames. Require edge detail to have a shared anchor.
                let rows = bodyHeight - acceptedOffset
                for direction in [1, -1] {
                    for x in stride(from: direction > 0 ? 0 : a.width - 1,
                                    through: direction > 0 ? a.width - 1 : 0, by: direction) {
                        var detail = false
                        for y in (header + 1)..<(a.height - footer) {
                            let index = (y * a.width + x) * 4
                            if delta(p, index, p, index - a.width * 4) > 12
                                || delta(q, index, q, index - a.width * 4) > 12 {
                                detail = true
                                break
                            }
                        }
                        if !detail { continue }
                        var sharedDetail = false
                        for y in 1..<rows {
                            let ai = ((header + acceptedOffset + y) * a.width + x) * 4
                            let bi = ((header + y) * a.width + x) * 4
                            if delta(p, ai, p, ai - a.width * 4) > 12 || delta(q, bi, q, bi - a.width * 4) > 12 {
                                sharedDetail = true
                                break
                            }
                        }
                        guard sharedDetail else { return nil }
                        break
                    }
                }
                return Match(offset: acceptedOffset, footer: footer)
            }
        }
    }

    private static func coarseOverlapMatches(
        _ a: Raster, _ b: Raster, startA: Int, startB: Int, rows: Int
    ) -> Bool {
        let rowCount = min(24, rows)
        let rowBytes = a.sampleWidth * 12
        return a.samples.withUnsafeBufferPointer { first in
            b.samples.withUnsafeBufferPointer { second in
                let p = first.baseAddress!
                let q = second.baseAddress!
                for row in 0..<rowCount {
                    let y = row * (rows - 1) / max(1, rowCount - 1)
                    let ai = (startA + y) * rowBytes
                    let bi = (startB + y) * rowBytes
                    for index in 0..<rowBytes {
                        let difference = abs(Int(p[ai + index]) - Int(q[bi + index]))
                        // Block extrema and averages cannot differ by more than
                        // the allowed per-pixel noise in a valid alignment.
                        if difference > 3 { return false }
                    }
                }
                return true
            }
        }
    }

    private static func nativeOverlapMatches(_ a: Raster, _ b: Raster, startA: Int, startB: Int, rows: Int) -> Bool {
        a.bytes.withUnsafeBytes { first in
            b.bytes.withUnsafeBytes { second in
                let p = first.bindMemory(to: UInt8.self).baseAddress!
                let q = second.bindMemory(to: UInt8.self).baseAddress!
                let count = rows * a.width
                var features = 0
                var informativeRows = 0
                var bias = [Int64](repeating: 0, count: 4)
                for y in 0..<rows {
                    var rowFeatures = 0
                    for x in 0..<a.width {
                        let ai = ((startA + y) * a.width + x) * 4
                        let bi = ((startB + y) * a.width + x) * 4
                        guard delta(p, ai, q, bi) <= 3 else { return false }
                        for channel in 0..<4 { bias[channel] += Int64(p[ai + channel]) - Int64(q[bi + channel]) }
                        let neighbor = y + 1 < rows ? a.width * 4 : -a.width * 4
                        let verticalDetail = delta(p, ai, p, ai + neighbor) > 12 || delta(q, bi, q, bi + neighbor) > 12
                        let horizontalDetail = x > 0 && (delta(p, ai, p, ai - 4) > 12 || delta(q, bi, q, bi - 4) > 12)
                        if verticalDetail || horizontalDetail {
                            features += 1
                            rowFeatures += 1
                        }
                    }
                    if rowFeatures > 0 { informativeRows += 1 }
                }
                return features >= max(4, min(32, count / 100))
                    && informativeRows >= min(8, rows)
                    && bias.allSatisfy { abs($0) * 2 <= Int64(count) }
            }
        }
    }
}
