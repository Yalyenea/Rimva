import Foundation
import CoreGraphics

public enum BackgroundPreset: String, CaseIterable, Codable, Identifiable {
    case dawn = "晨曦"
    case rose = "玫瑰"
    case iris = "鸢尾"
    case foam = "泡沫"
    case pine = "松林"
    case moon = "月夜"
    case dawnAbstract = "晨曦·抽象"
    case roseAbstract = "玫瑰·抽象"
    case irisAbstract = "鸢尾·抽象"
    case foamAbstract = "泡沫·抽象"
    case pineAbstract = "松林·抽象"
    case moonAbstract = "月夜·抽象"

    public var id: String { rawValue }
    public var name: String { L(String(rawValue.split(separator: "·")[0])) }
    public var variantTitle: String { L(isAbstract ? "抽象" : "渐变") }
    public var title: String { L("%@ · %@", name, variantTitle) }
    private var isAbstract: Bool { rawValue.contains("·") }

    private var resourceName: String {
        let color: String
        switch self {
        case .dawn, .dawnAbstract: color = "dawn"
        case .rose, .roseAbstract: color = "rose"
        case .iris, .irisAbstract: color = "iris"
        case .foam, .foamAbstract: color = "foam"
        case .pine, .pineAbstract: color = "pine"
        case .moon, .moonAbstract: color = "moon"
        }
        return "\(color)-\(isAbstract ? "abstract" : "gradient")"
    }

    public var imageURL: URL {
        // Presets are required package assets, independent of the user's image library.
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png") else {
            preconditionFailure("Missing bundled preset: \(resourceName).png")
        }
        return url
    }
}

public enum ShadowStyle: String, CaseIterable, Codable {
    case off, light, standard

    public var title: String {
        switch self {
        case .off: L("关")
        case .light: L("轻")
        case .standard: L("标准")
        }
    }
}

public enum RenderAppearance: String, Codable {
    case light, dark
}

public enum BackgroundSource: String, Codable, CaseIterable {
    case preset, image
}

public struct BackgroundStyle: Equatable, Codable {
    public var enabled: Bool
    public var preset: BackgroundPreset
    public var customHex: String?
    public var padding: Double
    public var rounded: Bool
    public var radius: Double
    public var shadow: ShadowStyle
    public var source: BackgroundSource
    public var lightImagePath: String?
    public var darkImagePath: String?
    public var followsAppearance: Bool

    public init(
        enabled: Bool = true,
        preset: BackgroundPreset = .iris,
        customHex: String? = nil,
        padding: Double = 48,
        rounded: Bool = true,
        radius: Double = 16,
        shadow: ShadowStyle = .light,
        source: BackgroundSource = .preset,
        lightImagePath: String? = nil,
        darkImagePath: String? = nil,
        followsAppearance: Bool = true
    ) {
        self.enabled = enabled
        self.preset = preset
        self.customHex = customHex
        self.padding = padding
        self.rounded = rounded
        self.radius = radius
        self.shadow = shadow
        self.source = source
        self.lightImagePath = lightImagePath
        self.darkImagePath = darkImagePath
        self.followsAppearance = followsAppearance
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, preset, customHex, padding, rounded, radius, shadow
        case source, lightImagePath, darkImagePath, followsAppearance
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        preset = try values.decode(BackgroundPreset.self, forKey: .preset)
        customHex = try values.decodeIfPresent(String.self, forKey: .customHex)
        padding = try values.decode(Double.self, forKey: .padding)
        rounded = try values.decode(Bool.self, forKey: .rounded)
        radius = try values.decode(Double.self, forKey: .radius)
        shadow = try values.decode(ShadowStyle.self, forKey: .shadow)
        // Existing preferences predate image backgrounds and retain their preset appearance.
        source = try values.decodeIfPresent(BackgroundSource.self, forKey: .source) ?? .preset
        lightImagePath = try values.decodeIfPresent(String.self, forKey: .lightImagePath)
        darkImagePath = try values.decodeIfPresent(String.self, forKey: .darkImagePath)
        followsAppearance = try values.decodeIfPresent(Bool.self, forKey: .followsAppearance) ?? true
    }

    public func imagePath(for appearance: RenderAppearance) -> String? {
        if followsAppearance, appearance == .dark, let darkImagePath { return darkImagePath }
        return lightImagePath ?? darkImagePath
    }
}

public enum AnnotationKind: String, Codable, CaseIterable {
    case arrow, rectangle, text, number, redact
}

public struct Annotation: Identifiable, Equatable {
    public var id: UUID
    public var kind: AnnotationKind
    public var start: CGPoint
    public var end: CGPoint
    public var text: String
    public var colorHex: String
    public var lineWidth: Double
    public var fontSize: Double
    public var number: Int

    public init(
        kind: AnnotationKind,
        start: CGPoint,
        end: CGPoint,
        id: UUID = UUID(),
        text: String = "",
        colorHex: String = "#EB6F92",
        lineWidth: Double = 4,
        fontSize: Double = 24,
        number: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.number = number
    }

    /// Coordinates always remain in the original image, including after a crop.
    public var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public func moved(by offset: CGSize) -> Self {
        var result = self
        result.start.x += offset.width
        result.start.y += offset.height
        result.end.x += offset.width
        result.end.y += offset.height
        return result
    }
}

public struct EditState: Equatable {
    public var crop: CGRect?
    public var annotations: [Annotation]

    public init(crop: CGRect? = nil, annotations: [Annotation] = []) {
        self.crop = crop
        self.annotations = annotations
    }
}
