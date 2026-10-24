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
        let next = try Raster(frame)
        if Self.equivalent(previous, next) { return .unchanged }
        guard height < Self.maximumHeight, height < Self.maximumPixels / width else { return .limitReached }
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

    /// Small cursor changes are tolerated only when surrounding content supplies
    /// enough unchanged detail. A mostly blank pair cannot pass on area alone.
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
        let samples: [UInt8]

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
            var sampled = [UInt8](repeating: 0, count: sampleWidth * height * 4)
            let source = memory.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<sampleWidth {
                    let sourceX = (x * width + width / 2) / sampleWidth
                    let sourceIndex = (y * width + sourceX) * 4
                    let targetIndex = (y * sampleWidth + x) * 4
                    for channel in 0..<4 { sampled[targetIndex + channel] = source[sourceIndex + channel] }
                }
            }
            samples = sampled
        }
    }

    private struct Match {
        let offset: Int
        let footer: Int
    }

    private struct Candidate {
        let offset: Int
        let score: Double
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
        let changeLimit = max(4, pixelCount / 500)
        return a.bytes.withUnsafeBytes { first in
            b.bytes.withUnsafeBytes { second in
                let p = first.bindMemory(to: UInt8.self).baseAddress!
                let q = second.bindMemory(to: UInt8.self).baseAddress!
                var changes = 0
                var stableDetail = 0
                var bias = [Int64](repeating: 0, count: 4)
                for index in stride(from: 0, to: first.count, by: 4) {
                    let difference = delta(p, index, q, index)
                    if difference > 3 {
                        changes += 1
                        if changes > changeLimit { return false }
                    } else if index >= a.width * 4, delta(p, index, p, index - a.width * 4) > 12 {
                        stableDetail += 1
                    } else if index % (a.width * 4) > 0, delta(p, index, p, index - 4) > 12 {
                        stableDetail += 1
                    }
                    for channel in 0..<4 { bias[channel] += Int64(p[index + channel]) - Int64(q[index + channel]) }
                }
                // A global color change is a different frame, even on a blank page.
                guard bias.allSatisfy({ abs($0) * 2 <= Int64(pixelCount) }) else { return false }
                return changes == 0 || stableDetail >= max(32, changes * 12)
            }
        }
    }

    private static func overlap(_ a: Raster, _ b: Raster) -> Match? {
        guard a.height >= 8 else { return nil }
        return a.samples.withUnsafeBufferPointer { first in
            b.samples.withUnsafeBufferPointer { second in
                let p = first.baseAddress!
                let q = second.baseAddress!
                let columns = a.sampleWidth
                func stationary(_ y: Int) -> Bool {
                    var error = 0
                    var changed = 0
                    for x in 0..<columns {
                        let index = (y * columns + x) * 4
                        let difference = delta(p, index, q, index)
                        error += min(difference, 32)
                        if difference > 8 { changed += 1 }
                    }
                    return changed <= columns / 20 && error <= columns * 2
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
                var candidates: [Candidate] = []
                for distance in 1...(bodyHeight - minimumOverlap) {
                    let rows = bodyHeight - distance
                    for direction in [-1, 1] {
                        let startA = header + (direction > 0 ? distance : 0)
                        let startB = header + (direction < 0 ? distance : 0)
                        if let score = coarseScore(p, q, columns: columns, startA: startA, startB: startB, rows: rows) {
                            candidates.append(Candidate(offset: distance * direction, score: score))
                        }
                    }
                }
                // Repeating patterns produce many equally plausible alignments.
                // Refusing them also bounds work on near-empty captures.
                guard !candidates.isEmpty, candidates.count <= 64 else { return nil }
                candidates.sort { $0.score < $1.score }
                var accepted: Candidate?
                for candidate in candidates {
                    let distance = abs(candidate.offset)
                    let startA = header + (candidate.offset > 0 ? distance : 0)
                    let startB = header + (candidate.offset < 0 ? distance : 0)
                    let rows = bodyHeight - distance
                    if sampledOverlapMatches(p, q, columns: columns, startA: startA, startB: startB, rows: rows) {
                        // Check upward alignments too: a periodic page must not turn
                        // an upward scroll into an apparently valid downward one.
                        guard accepted == nil else { return nil }
                        accepted = candidate
                    }
                }
                guard let accepted, accepted.offset > 0 else { return nil }
                let rows = bodyHeight - accepted.offset
                guard nativeOverlapMatches(a, b, startA: header + accepted.offset, startB: header, rows: rows) else { return nil }
                return Match(offset: accepted.offset, footer: footer)
            }
        }
    }

    private static func coarseScore(
        _ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, columns: Int, startA: Int, startB: Int, rows: Int
    ) -> Double? {
        let rowCount = min(24, rows)
        let columnCount = min(24, columns)
        let count = rowCount * columnCount
        var changed = 0
        var error = 0
        for row in 0..<rowCount {
            let y = row * (rows - 1) / max(1, rowCount - 1)
            for column in 0..<columnCount {
                let x = column * (columns - 1) / max(1, columnCount - 1)
                let difference = delta(a, ((startA + y) * columns + x) * 4, b, ((startB + y) * columns + x) * 4)
                if difference > 8 {
                    changed += 1
                    if changed > max(1, count / 20) { return nil }
                }
                error += min(difference, 32)
            }
        }
        guard error <= count * 3 else { return nil }
        return Double(error) / Double(count)
    }

    private static func sampledOverlapMatches(
        _ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, columns: Int, startA: Int, startB: Int, rows: Int
    ) -> Bool {
        var changes = 0
        var error = 0
        var features = 0
        var changedFeatures = 0
        var informativeRows = 0
        let count = rows * columns
        for y in 0..<rows {
            var rowFeatures = 0
            for x in 0..<columns {
                let ai = ((startA + y) * columns + x) * 4
                let bi = ((startB + y) * columns + x) * 4
                let difference = delta(a, ai, b, bi)
                error += min(difference, 32)
                if difference > 8 { changes += 1 }
                let neighbor = y + 1 < rows ? columns * 4 : -columns * 4
                let verticalDetail = delta(a, ai, a, ai + neighbor) > 12 || delta(b, bi, b, bi + neighbor) > 12
                let horizontalDetail = x > 0 && (delta(a, ai, a, ai - 4) > 12 || delta(b, bi, b, bi - 4) > 12)
                if verticalDetail || horizontalDetail {
                    features += 1
                    rowFeatures += 1
                    if difference > 8 { changedFeatures += 1 }
                }
            }
            if rowFeatures > 0 { informativeRows += 1 }
            if changes > max(1, count / 33) { return false }
        }
        return error <= count * 3 && features >= max(4, min(32, count / 100))
            && informativeRows >= max(2, min(8, rows / 8))
            && changedFeatures <= features / 12
    }

    private static func nativeOverlapMatches(_ a: Raster, _ b: Raster, startA: Int, startB: Int, rows: Int) -> Bool {
        a.bytes.withUnsafeBytes { first in
            b.bytes.withUnsafeBytes { second in
                let p = first.bindMemory(to: UInt8.self).baseAddress!
                let q = second.bindMemory(to: UInt8.self).baseAddress!
                let count = rows * a.width
                var changes = 0
                var badRows = 0
                var error = 0
                for y in 0..<rows {
                    var rowChanges = 0
                    for x in 0..<a.width {
                        let difference = delta(p, ((startA + y) * a.width + x) * 4, q, ((startB + y) * a.width + x) * 4)
                        error += min(difference, 32)
                        if difference > 8 {
                            rowChanges += 1
                            changes += 1
                            if changes > max(2, count / 66) { return false }
                        }
                    }
                    if rowChanges > a.width / 6 { badRows += 1 }
                    if badRows > max(1, rows / 25) { return false }
                }
                return error <= count * 3
            }
        }
    }
}
