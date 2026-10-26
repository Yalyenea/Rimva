import Foundation
import CoreGraphics
import ScreenCaptureKit
import RimvaCore

@MainActor
enum NativeWindowCapture {
    static func image(of windowID: CGWindowID, includesCursor: Bool) async throws -> CGImage {
        // Resolve the ID again at confirmation: live windows may have moved or resized.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else { throw Failure.noDisplay }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw Failure.unavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // The native shadow lies outside contentRect. Room on the transparent canvas
        // prevents ScreenCaptureKit from shrinking the window to fit its own shadow.
        let width = ((filter.contentRect.width + 256) * scale).rounded(.up)
        let height = ((filter.contentRect.height + 256) * scale).rounded(.up)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 32_768, height <= 32_768, width * height <= 100_000_000 else {
            throw ImageRenderingError.imageTooLarge
        }
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = false
        configuration.shouldBeOpaque = false
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.showsCursor = includesCursor
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try await Task.detached(priority: .userInitiated) { try trimTransparentBorder(image) }.value
    }

    nonisolated static func trimTransparentBorder(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              width * height <= 100_000_000 else { throw ImageRenderingError.imageTooLarge }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bounds = try pixels.withUnsafeMutableBytes { bytes -> CGRect in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ImageRenderingError.allocationFailed
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = bytes.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where pixels[(y * width + x) * 4 + 3] != 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { throw Failure.unavailable }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        // Crop the original pixels, including every nonzero-alpha native shadow pixel.
        guard let result = image.cropping(to: bounds) else { throw Failure.unavailable }
        return result
    }

    private enum Failure: LocalizedError {
        case unavailable, noDisplay
        var errorDescription: String? {
            switch self {
            case .unavailable: L("目标窗口已关闭或无法共享，请重新选择。")
            case .noDisplay: L("无法找到可截图的显示器。请检查显示器连接后重试。")
            }
        }
    }
}
