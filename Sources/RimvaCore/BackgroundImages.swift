import Foundation
import CoreGraphics
import ImageIO

/// Shared decoding keeps gallery thumbnails and repeated editor redraws off full-size image data.
public enum BackgroundImages {
    private final class CachedImage {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private final class Dimensions {
        let width: Double
        let height: Double
        init(width: Double, height: Double) { self.width = width; self.height = height }
    }

    private static let metadata: NSCache<NSString, Dimensions> = {
        let cache = NSCache<NSString, Dimensions>()
        cache.countLimit = 512
        return cache
    }()

    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 128 * 1_024 * 1_024
        cache.countLimit = 128
        return cache
    }()

    public static func thumbnail(url: URL, maxPixelSize: Int = 320) -> CGImage? {
        try? decoded(url: url, maximum: max(1, min(maxPixelSize, 8_192)))
    }

    static func image(url: URL, targetSize: CGSize) throws -> CGImage {
        try decoded(url: url, maximum: 8_192, targetSize: targetSize)
    }

    private static func decoded(url: URL, maximum: Int, targetSize: CGSize? = nil) throws -> CGImage {
        let failure = ImageRenderingError.unreadableBackgroundImage(url.lastPathComponent)
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { throw failure }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        // A changed file must not leave an old cached preview in the exported result.
        let identity = "\(url.standardizedFileURL.path)|\(modified)|\(fileSize)" as NSString
        var imageSource: CGImageSource?
        let dimensions: Dimensions
        if let cached = metadata.object(forKey: identity) {
            dimensions = cached
        } else {
            imageSource = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            guard let imageSource,
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  width > 0, height > 0, width.isFinite, height.isFinite else { throw failure }
            dimensions = Dimensions(width: width, height: height)
            metadata.setObject(dimensions, forKey: identity)
        }
        let width = dimensions.width
        let height = dimensions.height
        var limit = Double(maximum)
        if let targetSize {
            // Bucket sizes prevent a slider gesture from decoding the source for every pixel.
            let scale = max(targetSize.width / width, targetSize.height / height)
            let needed = max(width, height) * scale
            limit = min(8_192, pow(2, ceil(log2(max(256, needed)))))
        }
        // ImageIO downsamples before decoding, bounding memory even for panoramic originals.
        let aspect = min(width, height) / max(width, height)
        limit = min(limit, sqrt(32_000_000 / aspect), max(width, height))
        let key = "\(identity)|\(Int(ceil(limit)))" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let source = imageSource ?? CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw failure }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(limit))),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw failure }
        cache.setObject(CachedImage(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
