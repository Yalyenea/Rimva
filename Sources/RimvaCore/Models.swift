import Foundation
import CoreGraphics

public enum BackgroundPreset: String, CaseIterable, Codable, Identifiable {
    case mist = "晨雾"
    case white = "雾白"
    case graphite = "石墨"
    case sand = "浅沙"
    case sage = "青灰"
    case blue = "暮蓝"

    public var id: String { rawValue }
    public var title: String { L(rawValue) }

    public var colors: [String] {
        switch self {
        case .mist: ["#E9E7F1", "#DCE8ED"]
        case .white: ["#F4F3F0"]
        case .graphite: ["#25272A"]
        case .sand: ["#F0E4D5", "#E8D3CA"]
        case .sage: ["#DDE7E2", "#BACBC5"]
        case .blue: ["#D4DFF0", "#B7C7E1"]
        }
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
        preset: BackgroundPreset = .mist,
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
        colorHex: String = "#FF573D",
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
