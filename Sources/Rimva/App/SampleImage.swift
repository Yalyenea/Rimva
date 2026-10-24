import AppKit

enum SampleImage {
    /// A local example lets the editor be tried before granting capture permission.
    static func make() -> CGImage? {
        let width = 1440, height = 900
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 2, y: -2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: alpha).cgColor
        }
        func shade(_ path: CGPath, _ colors: [UInt32], from start: CGPoint, to end: CGPoint) {
            context.saveGState()
            context.addPath(path); context.clip()
            let gradient = CGGradient(colorsSpace: space, colors: colors.map { color($0) } as CFArray, locations: nil)!
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
        func polygon(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points); path.closeSubpath()
            return path
        }
        func shadow(_ rect: CGRect, blur: CGFloat, opacity: CGFloat) {
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: rect.width / 2 + blur, y: rect.height / 2 + blur / 2)
            let gradient = CGGradient(colorsSpace: space, colors: [color(0x575279, alpha: opacity), color(0x575279, alpha: 0)] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
        }

        shade(CGPath(rect: CGRect(x: 0, y: 0, width: 720, height: 450), transform: nil),
              [0xF5F1EB, 0xEDE8E6, 0xE7E2E3], from: .zero, to: CGPoint(x: 720, y: 450))
        let light = CGGradient(colorsSpace: space, colors: [color(0xFFFAF4, alpha: 0.65), color(0xFFFAF4, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(light, startCenter: CGPoint(x: 160, y: 80), startRadius: 0,
                                  endCenter: CGPoint(x: 160, y: 80), endRadius: 440, options: [])
        shade(CGPath(rect: CGRect(x: 0, y: 299, width: 720, height: 151), transform: nil),
              [0xEAE5E0, 0xE1DBD7], from: CGPoint(x: 0, y: 299), to: CGPoint(x: 720, y: 450))

        shadow(CGRect(x: 177, y: 359, width: 396, height: 15), blur: 23, opacity: 0.10)
        shade(CGPath(rect: CGRect(x: 160, y: 346, width: 385, height: 25), transform: nil),
              [0xDDD6CF, 0xCBC1BC], from: CGPoint(x: 160, y: 346), to: CGPoint(x: 545, y: 371))
        shade(polygon([CGPoint(x: 545, y: 346), CGPoint(x: 570, y: 323), CGPoint(x: 570, y: 348), CGPoint(x: 545, y: 371)]),
              [0xD2C9C3, 0xBDB1AC], from: CGPoint(x: 545, y: 323), to: CGPoint(x: 570, y: 371))
        shade(polygon([CGPoint(x: 160, y: 346), CGPoint(x: 185, y: 323), CGPoint(x: 570, y: 323), CGPoint(x: 545, y: 346)]),
              [0xF0EBE4, 0xDED6CF], from: CGPoint(x: 185, y: 323), to: CGPoint(x: 545, y: 346))
        shadow(CGRect(x: 231, y: 327, width: 151, height: 10), blur: 12, opacity: 0.10)
        shadow(CGRect(x: 394, y: 336, width: 146, height: 10), blur: 10, opacity: 0.10)

        let vase = CGMutablePath()
        vase.move(to: CGPoint(x: 269, y: 124))
        vase.addLine(to: CGPoint(x: 319, y: 124))
        vase.addLine(to: CGPoint(x: 319, y: 158))
        vase.addCurve(to: CGPoint(x: 356, y: 216), control1: CGPoint(x: 319, y: 181), control2: CGPoint(x: 346, y: 187))
        vase.addCurve(to: CGPoint(x: 369, y: 292), control1: CGPoint(x: 365, y: 239), control2: CGPoint(x: 374, y: 269))
        vase.addCurve(to: CGPoint(x: 340, y: 332), control1: CGPoint(x: 366, y: 322), control2: CGPoint(x: 357, y: 332))
        vase.addCurve(to: CGPoint(x: 249, y: 332), control1: CGPoint(x: 314, y: 336), control2: CGPoint(x: 272, y: 336))
        vase.addCurve(to: CGPoint(x: 220, y: 292), control1: CGPoint(x: 231, y: 331), control2: CGPoint(x: 215, y: 317))
        vase.addCurve(to: CGPoint(x: 235, y: 216), control1: CGPoint(x: 218, y: 263), control2: CGPoint(x: 226, y: 237))
        vase.addCurve(to: CGPoint(x: 269, y: 158), control1: CGPoint(x: 242, y: 190), control2: CGPoint(x: 269, y: 183))
        vase.closeSubpath()
        shade(vase, [0xA1AFB2, 0xCED5D2, 0xAAB7B8, 0x7C8D95], from: CGPoint(x: 218, y: 208), to: CGPoint(x: 375, y: 231))
        let opening = CGRect(x: 269, y: 120, width: 50, height: 9)
        shade(CGPath(ellipseIn: opening, transform: nil), [0x71828A, 0x9DABAD],
              from: CGPoint(x: 269, y: 120), to: CGPoint(x: 319, y: 129))
        context.setStrokeColor(color(0xD9DFDC)); context.setLineWidth(1.2)
        context.strokeEllipse(in: opening)

        let bowl = CGMutablePath()
        bowl.move(to: CGPoint(x: 387, y: 296))
        bowl.addCurve(to: CGPoint(x: 462, y: 346), control1: CGPoint(x: 393, y: 333), control2: CGPoint(x: 414, y: 346))
        bowl.addCurve(to: CGPoint(x: 540, y: 296), control1: CGPoint(x: 512, y: 346), control2: CGPoint(x: 534, y: 329))
        bowl.closeSubpath()
        shade(bowl, [0xEFE8DE, 0xE5DAD1, 0xBFAEAD], from: CGPoint(x: 389, y: 293), to: CGPoint(x: 537, y: 347))
        shade(CGPath(ellipseIn: CGRect(x: 387, y: 281, width: 153, height: 31), transform: nil),
              [0xF4EDE3, 0xD9CCC4], from: CGPoint(x: 398, y: 281), to: CGPoint(x: 530, y: 312))
        shade(CGPath(ellipseIn: CGRect(x: 394, y: 286, width: 139, height: 21), transform: nil),
              [0xB6A4A5, 0xD9CBC3, 0xE5DAD1], from: CGPoint(x: 424, y: 285), to: CGPoint(x: 476, y: 308))
        return context.makeImage()
    }
}
