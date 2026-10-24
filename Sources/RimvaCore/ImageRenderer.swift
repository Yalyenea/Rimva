import AppKit
import CoreGraphics

public enum ImageRenderingError: LocalizedError {
    case invalidCrop
    case invalidStyle
    case invalidAnnotation
    case invalidColor(String)
    case imageTooLarge
    case allocationFailed
    case missingBackgroundImage
    case unreadableBackgroundImage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCrop: L("裁剪范围无效，请重新选择。")
        case .invalidStyle: L("留白或圆角数值无效。")
        case .invalidAnnotation: L("标注的位置或尺寸无效。")
        case .invalidColor(let value): L("无法识别颜色 %@，请重新选择。", value)
        case .imageTooLarge: L("图片尺寸过大，请缩小裁剪范围或留白。")
        case .allocationFailed: L("无法生成图片，内存可能不足。")
        case .missingBackgroundImage: L("请选择背景图片。")
        case .unreadableBackgroundImage(let name): L("无法读取背景图片：%@", name)
        }
    }
}

public enum ImageRenderer {
    private struct Layout {
        var crop: CGRect
        var content: CGRect
        var size: CGSize
    }

    private struct Shadow {
        var blur: CGFloat
        var offset: CGFloat
        var opacity: CGFloat
    }

    /// Returns zero for an invalid layout. Rendering reports the specific error.
    public static func outputSize(image: CGImage, state: EditState, style: BackgroundStyle) -> CGSize {
        (try? layout(image: image, state: state, style: style).size) ?? .zero
    }

    /// The editor uses this same inset to map pointer positions back to source pixels.
    public static func contentRect(image: CGImage, state: EditState, style: BackgroundStyle) -> CGRect {
        (try? layout(image: image, state: state, style: style).content) ?? .zero
    }

    public static func annotationFont(size: Double) -> NSFont {
        NSFont.systemFont(ofSize: CGFloat(size), weight: .semibold)
    }

    public static func annotationTextAttributes(colorHex: String, fontSize: Double) throws -> [NSAttributedString.Key: Any] {
        guard let color = color(hex: colorHex) else { throw ImageRenderingError.invalidColor(colorHex) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: annotationFont(size: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    /// Six-digit RGB keeps redaction colors opaque and avoids accidental alpha values.
    public static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255,
            alpha: 1
        )
    }

    public static func render(image: CGImage, state: EditState, style: BackgroundStyle, appearance: RenderAppearance = .light) throws -> CGImage {
        let layout = try layout(image: image, state: state, style: style)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: Int(layout.size.width),
            height: Int(layout.size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageRenderingError.allocationFailed }

        // A single top-left coordinate system serves imported images and editor gestures.
        context.translateBy(x: 0, y: layout.size.height)
        context.scaleBy(x: 1, y: -1)
        try draw(image: image, state: state, style: style, appearance: appearance, in: context)

        guard let output = context.makeImage() else { throw ImageRenderingError.allocationFailed }
        return output
    }

    /// Draws into an existing top-left, Y-down context without allocating another full image.
    /// The caller may scale the context; the original pixel coordinate model stays unchanged.
    public static func draw(image: CGImage, state: EditState, style: BackgroundStyle, appearance: RenderAppearance = .light, in context: CGContext) throws {
        let layout = try layout(image: image, state: state, style: style)
        try validate(annotations: state.annotations)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: layout.size))
        context.interpolationQuality = .high

        if style.enabled {
            try drawBackground(style, appearance: appearance, size: layout.size, in: context, colorSpace: colorSpace)
        }

        let radius = style.enabled && style.rounded
            ? min(CGFloat(style.radius), min(layout.content.width, layout.content.height) / 2)
            : 0
        let outline = CGPath(roundedRect: layout.content, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.enabled, let shadow = shadow(for: style.shadow) {
            context.saveGState()
            // Keep the shadow caster outside the content, so transparent PNGs reveal the background.
            context.addRect(CGRect(origin: .zero, size: layout.size))
            context.addPath(outline)
            context.clip(using: .evenOdd)
            // Shadows use base-space values, so scale their metrics with the preview transform.
            let transform = context.ctm
            let scale = hypot(transform.a, transform.b)
            context.setShadow(
                offset: CGSize(width: transform.c * shadow.offset, height: transform.d * shadow.offset),
                blur: shadow.blur * scale,
                color: NSColor.black.withAlphaComponent(shadow.opacity).cgColor
            )
            context.addPath(outline)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.translateBy(x: layout.content.minX - layout.crop.minX, y: layout.content.minY - layout.crop.minY)
        let redactions = state.annotations.enumerated().compactMap { index, item -> (Int, CGRect)? in
            item.kind == .redact ? (index, item.rect.integral) : nil
        }
        // Excluding covered pixels before drawing prevents source colors surviving repeated
        // antialiasing at rounded edges, without allocating a full-size preview bitmap.
        drawExcludingRedactions(redactions.map(\.1), crop: layout.crop, in: context) {
            drawSource(image, in: context)
        }
        for (index, annotation) in state.annotations.enumerated() {
            let laterRedactions = redactions.compactMap { $0.0 > index ? $0.1 : nil }
            try drawExcludingRedactions(laterRedactions, crop: layout.crop, in: context) {
                try draw(annotation, in: context)
            }
        }
        context.restoreGState()

    }

    private static func layout(image: CGImage, state: EditState, style: BackgroundStyle) throws -> Layout {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var crop = bounds
        if let requested = state.crop {
            guard requested.isFinite, requested.width > 0, requested.height > 0 else {
                throw ImageRenderingError.invalidCrop
            }
            crop = requested.integral.intersection(bounds)
            guard !crop.isNull, !crop.isEmpty else { throw ImageRenderingError.invalidCrop }
        }
        var padding: CGFloat = 0
        if style.enabled {
            guard style.padding.isFinite, style.radius.isFinite,
                  style.padding >= 0, style.radius >= 0 else { throw ImageRenderingError.invalidStyle }
            padding = ceil(CGFloat(style.padding))
            if let shadow = shadow(for: style.shadow) {
                // A conservative finite footprint keeps both shadow presets off canvas edges.
                padding = max(padding, ceil(shadow.blur * 2 + shadow.offset))
            }
        }
        let size = CGSize(width: crop.width + padding * 2, height: crop.height + padding * 2)
        // Validate before integer conversion and allocation, including malicious imported values.
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= 32_768, size.height <= 32_768,
              size.width * size.height <= 100_000_000 else { throw ImageRenderingError.imageTooLarge }
        return Layout(crop: crop, content: CGRect(origin: CGPoint(x: padding, y: padding), size: crop.size), size: size)
    }

    private static func shadow(for style: ShadowStyle) -> Shadow? {
        switch style {
        case .off: nil
        case .light: Shadow(blur: 24, offset: 8, opacity: 0.12)
        case .standard: Shadow(blur: 40, offset: 12, opacity: 0.20)
        }
    }

    private static func drawBackground(
        _ style: BackgroundStyle, appearance: RenderAppearance, size: CGSize, in context: CGContext, colorSpace: CGColorSpace
    ) throws {
        if style.source == .image {
            guard let path = style.imagePath(for: appearance) else { throw ImageRenderingError.missingBackgroundImage }
            let image = try BackgroundImages.image(url: URL(fileURLWithPath: path), targetSize: size)
            let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: (size.width - width) / 2, y: (size.height - height) / 2)
            context.scaleBy(x: scale, y: scale)
            drawSource(image, in: context)
            return
        }
        let hexColors = style.customHex.map { [$0] } ?? style.preset.colors
        let colors = try hexColors.map { hex -> CGColor in
            guard let color = color(hex: hex) else { throw ImageRenderingError.invalidColor(hex) }
            return color.cgColor
        }
        if colors.count == 1 {
            context.setFillColor(colors[0])
            context.fill(CGRect(origin: .zero, size: size))
        } else {
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) else {
                throw ImageRenderingError.allocationFailed
            }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }

    private static func drawSource(_ image: CGImage, in context: CGContext) {
        context.saveGState()
        // CGImage drawing is bottom-up even inside a flipped user coordinate system.
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }

    private static func drawExcludingRedactions(
        _ rects: [CGRect], crop: CGRect, in context: CGContext, body: () throws -> Void
    ) rethrows {
        context.saveGState()
        defer { context.restoreGState() }
        for rect in rects where !rect.isEmpty {
            // Intersect separate inverse clips; a single even-odd path would expose overlaps.
            context.addRect(crop)
            context.addRect(rect)
            context.clip(using: .evenOdd)
        }
        try body()
    }

    private static func validate(annotations: [Annotation]) throws {
        for item in annotations {
            guard item.start.x.isFinite, item.start.y.isFinite, item.end.x.isFinite, item.end.y.isFinite,
                  abs(item.start.x) <= 1_000_000, abs(item.start.y) <= 1_000_000,
                  abs(item.end.x) <= 1_000_000, abs(item.end.y) <= 1_000_000,
                  item.lineWidth.isFinite, item.lineWidth > 0, item.lineWidth <= 4_096,
                  item.fontSize.isFinite, item.fontSize > 0, item.fontSize <= 4_096 else {
                throw ImageRenderingError.invalidAnnotation
            }
            guard color(hex: item.colorHex) != nil else { throw ImageRenderingError.invalidColor(item.colorHex) }
        }
    }

    private static func draw(_ item: Annotation, in context: CGContext) throws {
        guard let color = color(hex: item.colorHex) else { throw ImageRenderingError.invalidColor(item.colorHex) }
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(CGFloat(item.lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch item.kind {
        case .redact:
            // Expand to whole pixels and disable edge blending so no source pixel leaks through.
            context.setShouldAntialias(false)
            context.fill(item.rect.integral)
        case .rectangle:
            context.stroke(item.rect)
        case .arrow:
            let dx = item.end.x - item.start.x
            let dy = item.end.y - item.start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let head = min(max(CGFloat(item.lineWidth) * 3.5, 12), length * 0.6)
            let angle = atan2(dy, dx)
            context.move(to: item.start)
            context.addLine(to: item.end)
            context.strokePath()
            for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                context.move(to: item.end)
                context.addLine(to: CGPoint(
                    x: item.end.x - cos(angle + delta) * head,
                    y: item.end.y - sin(angle + delta) * head
                ))
            }
            context.strokePath()
        case .text:
            drawText(item.text, rect: item.rect, attributes: try annotationTextAttributes(colorHex: item.colorHex, fontSize: item.fontSize), in: context)
        case .number:
            let diameter = max(28, max(item.rect.width, item.rect.height))
            let circle = CGRect(origin: item.rect.origin, size: CGSize(width: diameter, height: diameter))
            context.fillEllipse(in: circle)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let font = annotationFont(size: min(item.fontSize, Double(diameter * 0.6)))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
            ]
            let label = String(item.number)
            let height = ceil((label as NSString).size(withAttributes: attributes).height)
            let textRect = CGRect(x: circle.minX, y: circle.midY - height / 2, width: diameter, height: height)
            drawText(label, rect: textRect, attributes: attributes, in: context)
        }
    }

    private static func drawText(
        _ text: String, rect: CGRect, attributes: [NSAttributedString.Key: Any], in context: CGContext
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
    }
}
