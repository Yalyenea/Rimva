import AppKit

enum SampleImage {
    /// A local example lets the editor be tried before granting capture permission.
    static func make() -> CGImage? {
        let width = 1440, height = 900
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 2, y: -2)
        context.setFillColor(NSColor(srgbRed: 0.979, green: 0.977, blue: 0.964, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 450))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = .darkGray, serif: Bool = false) {
            let font = serif ? (NSFont(name: "Songti SC", size: size) ?? .systemFont(ofSize: size)) : .systemFont(ofSize: size)
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        let muted = NSColor(srgbRed: 0.52, green: 0.55, blue: 0.51, alpha: 1)
        context.setFillColor(muted.cgColor); context.fillEllipse(in: CGRect(x: 20, y: 14, width: 7, height: 7))
        label("野外手记", x: 34, y: 10, size: 11, color: muted)
        label("随手记录，慢慢生活", x: 574, y: 10, size: 11, color: muted)
        context.setStrokeColor(muted.withAlphaComponent(0.14).cgColor); context.setLineWidth(0.5); context.move(to: CGPoint(x: 0, y: 34)); context.addLine(to: CGPoint(x: 720, y: 34)); context.strokePath()
        label("F I E L D  N O T E S     /     0 7", x: 32, y: 66, size: 10, color: muted)
        label("把日子\n过慢一点。", x: 32, y: 102, size: 31, color: NSColor(srgbRed: 0.20, green: 0.24, blue: 0.21, alpha: 1), serif: true)
        label("周末，留给山野", x: 32, y: 214, size: 13)
        label("沿着山路向前，听风穿过树林。\n带上相机，也留一点空白。", x: 32, y: 249, size: 12, color: muted)
        context.setStrokeColor(muted.withAlphaComponent(0.3).cgColor); context.move(to: CGPoint(x: 32, y: 305)); context.addLine(to: CGPoint(x: 364, y: 305)); context.strokePath()
        label("2026.10.22     ·     6 分钟阅读", x: 32, y: 321, size: 10, color: muted)
        let art = CGRect(x: 392, y: 64, width: 296, height: 350)
        context.saveGState(); context.addPath(CGPath(roundedRect: art, cornerWidth: 3, cornerHeight: 3, transform: nil)); context.clip()
        context.setFillColor(NSColor(srgbRed: 0.84, green: 0.89, blue: 0.84, alpha: 1).cgColor); context.fill(art)
        context.setFillColor(NSColor(srgbRed: 0.95, green: 0.93, blue: 0.82, alpha: 1).cgColor); context.fillEllipse(in: CGRect(x: 605, y: 104, width: 52, height: 52))
        func mountain(_ points: [CGPoint], color: NSColor) { context.beginPath(); context.addLines(between: points); context.closePath(); context.setFillColor(color.cgColor); context.fillPath() }
        mountain([CGPoint(x: 392,y: 298),CGPoint(x: 498,y: 142),CGPoint(x: 616,y: 318),CGPoint(x: 688,y: 246),CGPoint(x: 688,y: 414),CGPoint(x: 392,y: 414)], color: NSColor(srgbRed: 0.64, green: 0.73, blue: 0.64, alpha: 1))
        mountain([CGPoint(x: 392,y: 344),CGPoint(x: 524,y: 234),CGPoint(x: 612,y: 344),CGPoint(x: 688,y: 288),CGPoint(x: 688,y: 414),CGPoint(x: 392,y: 414)], color: NSColor(srgbRed: 0.47, green: 0.58, blue: 0.49, alpha: 1))
        mountain([CGPoint(x: 392,y: 398),CGPoint(x: 478,y: 310),CGPoint(x: 588,y: 414)], color: NSColor(srgbRed: 0.32, green: 0.44, blue: 0.36, alpha: 1))
        context.setStrokeColor(NSColor(srgbRed: 0.88, green: 0.88, blue: 0.73, alpha: 1).cgColor); context.setLineWidth(4); context.addLines(between: [CGPoint(x: 555,y: 414),CGPoint(x: 574,y: 368),CGPoint(x: 544,y: 348),CGPoint(x: 573,y: 322)]); context.strokePath()
        label("北纬 30° / 一段慢行", x: 408, y: 386, size: 10, color: NSColor(srgbRed: 0.91, green: 0.94, blue: 0.87, alpha: 1))
        context.restoreGState()
        return context.makeImage()
    }
}
