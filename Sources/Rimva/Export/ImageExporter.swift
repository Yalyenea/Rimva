import AppKit
import ImageIO
import RimvaCore
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case encoding, clipboard, unreadable, undecodable
    var errorDescription: String? {
        switch self {
        case .encoding: L("无法生成 PNG 图片。")
        case .clipboard: L("剪贴板暂时不可用，请重试。")
        case .unreadable: L("无法读取这张图片，请选择 PNG 或 JPEG。")
        case .undecodable: L("无法解码这张图片。")
        }
    }
}

enum ImageExporter {
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.encoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encoding }
        return data as Data
    }

    @MainActor static func copy(_ image: CGImage) throws {
        let data = try png(image)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(data, forType: .png) else { throw ExportError.clipboard }
    }

    static func suggestedName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Rimva \(formatter.string(from: Date())).png"
    }

    static func save(_ image: CGImage, to url: URL) throws {
        try png(image).write(to: url, options: .atomic)
    }

    static func saveAutomatically(_ image: CGImage, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (suggestedName() as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name + ".png")
        var suffix = 2
        // Rapid captures can share a timestamp; each capture must keep its own file.
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(suffix).png")
            suffix += 1
        }
        try save(image, to: url)
        return url
    }

    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let contentType = UTType(type as String),
              contentType.conforms(to: .png) || contentType.conforms(to: .jpeg) else {
            throw ExportError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        // Apply camera orientation without reducing the original pixel dimensions.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                                       kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ExportError.undecodable
        }
        return image
    }
}
