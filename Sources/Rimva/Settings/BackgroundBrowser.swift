import AppKit
import RimvaCore
import SwiftUI

struct BackgroundBrowser: View {
    @Binding var style: RimvaCore.BackgroundStyle
    @Binding var previewAppearance: RenderAppearance
    var compact = false
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var library = BackgroundLibrary.shared
    @State private var source: BrowserSource = .presets
    @State private var selectedFolder: URL?

    private var palette: ThemePalette { preferences.palette }
    private var selectedPath: String? {
        previewAppearance == .light ? style.lightImagePath : style.darkImagePath
    }
    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 110), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                ThemedSegments(selection: $source, values: BrowserSource.allCases) { Text($0.title) }
                    .frame(maxWidth: 330).accessibilityLabel(L("背景来源"))
                Spacer(minLength: 0)
                ThemedSegments(selection: $previewAppearance, values: [.light, .dark]) { appearance in
                    Image(systemName: appearance == .light ? "sun.max" : "moon")
                        .accessibilityLabel(appearance == .light ? L("日间背景") : L("夜间背景"))
                }.frame(width: 74)
                .help(previewAppearance == .light ? L("日间背景") : L("夜间背景"))
            }
            switch source {
            case .presets: presets
            case .images: images
            case .folders: folders
            case .macOS: assets(library.wallpapers)
            }
            if style.source == .image, let selectedPath {
                HStack(spacing: 7) {
                    Image(systemName: previewAppearance == .light ? "sun.max" : "moon")
                    Text(URL(fileURLWithPath: selectedPath).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: palette.secondary))
                .help(selectedPath)
            }
            if let error = library.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Color(nsColor: palette.error))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color(nsColor: palette.text))
        .tint(Color(nsColor: palette.accent))
        .onAppear {
            guard style.source == .image else { return }
            if library.wallpapers.contains(where: { $0.url.path == selectedPath }) {
                source = .macOS
            } else if let folder = library.folders.first(where: {
                selectedPath?.hasPrefix($0.path + "/") == true
            }) {
                selectedFolder = folder
                source = .folders
            } else { source = .images }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 15) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 40), spacing: 10), count: compact ? 3 : 6), alignment: .leading, spacing: 14) {
                ForEach(BackgroundPreset.allCases) { preset in
                    let selected = style.source == .preset && style.customHex == nil && style.preset == preset
                    Button {
                        var next = style
                        next.source = .preset
                        next.preset = preset
                        next.customHex = nil
                        style = next
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(LinearGradient(colors: preset.colors.compactMap {
                                    RimvaCore.ImageRenderer.color(hex: $0).map { Color(nsColor: $0) }
                                }, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .aspectRatio(1.5, contentMode: .fit)
                                .overlay(selectionOutline(selected))
                            Text(preset.title).font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: selected ? palette.accent : palette.secondary))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                Text(L("纯色"))
                CompactColorWell(color: Binding(get: { NSColor(customColor.wrappedValue) },
                                               set: { customColor.wrappedValue = Color(nsColor: $0) }), title: L("背景颜色"))
                    .frame(width: 24, height: 26)
                if style.source == .preset, let hex = style.customHex {
                    Text(hex).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: palette.secondary))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: 14) {
            addButton(L("添加图片"), action: library.addImages)
            assets(library.images)
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                addButton(L("添加文件夹"), action: library.addFolder)
                Spacer(minLength: 0)
            }
            if !library.folders.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(library.folders, id: \.self) { folder in
                        Button { selectedFolder = folder } label: {
                            Label(folder.lastPathComponent, systemImage: "folder")
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .foregroundStyle(Color(nsColor: palette.text))
                                .background(Color(nsColor: selectedFolder == folder ? palette.selection : palette.elevated), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain).help(folder.path)
                        .accessibilityAddTraits(selectedFolder == folder ? .isSelected : [])
                    }
                }
            }
            if let folder = selectedFolder ?? library.folders.first {
                assets(library.assets(in: folder))
            }
        }
        .onAppear { if selectedFolder == nil { selectedFolder = library.folders.first } }
        .onChange(of: library.folders) { _, folders in
            if selectedFolder == nil { selectedFolder = folders.first }
        }
    }

    private func assets(_ assets: [BackgroundAsset]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(assets) { asset in
                let selected = style.source == .image && selectedPath == asset.url.path
                Button {
                    var next = style
                    next.source = .image
                    if previewAppearance == .light { next.lightImagePath = asset.url.path }
                    else { next.darkImagePath = asset.url.path }
                    style = next
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        BackgroundThumbnail(url: asset.url, background: palette.elevated)
                            .aspectRatio(1.5, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(selectionOutline(selected))
                        Text(asset.name).font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: selected ? palette.accent : palette.secondary))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(asset.url.path)
                .accessibilityLabel(asset.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func selectionOutline(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .stroke(Color(nsColor: selected ? palette.accent : palette.separator), lineWidth: selected ? 2 : 0.5)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: "plus") }
            .buttonStyle(.plain).foregroundStyle(Color(nsColor: palette.secondaryAccent))
            .fixedSize()
    }

    private var customColor: Binding<Color> {
        Binding(get: {
            Color(nsColor: RimvaCore.ImageRenderer.color(hex: style.customHex ?? "#F4F3F0") ?? .white)
        }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            var next = style
            next.source = .preset
            next.customHex = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                                     Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            style = next
        })
    }
}

private enum BrowserSource: String, CaseIterable, Identifiable {
    case presets, images, folders, macOS
    var id: String { rawValue }
    var title: String {
        switch self {
        case .presets: L("预设")
        case .images: L("图片")
        case .folders: L("文件夹")
        case .macOS: "macOS"
        }
    }
}

private struct BackgroundThumbnail: View {
    var url: URL
    var background: NSColor
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: background)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
        }
        .task(id: url) {
            let targetURL = url
            // ImageIO decoding stays off the main thread while the grid is populated.
            let thumbnail = await Task.detached(priority: .utility) {
                BackgroundImages.thumbnail(url: targetURL, maxPixelSize: 256)
            }.value
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
    }
}
