import AppKit
import RimvaCore
import SwiftUI

// Settings and the editor share the same metrics and bindings for style controls.
struct BackgroundStyleControls: View {
    @Binding var style: RimvaCore.BackgroundStyle
    var compact = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                toggleRow(L("背景"), isOn: $style.enabled)
                toggleRow(compact ? L("自动切换") : L("跟随外观"), isOn: $style.followsAppearance)
                    .disabled(!style.enabled).help(L("跟随外观"))
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 4) {
                    HStack {
                        Text(L("留白"))
                        Spacer(minLength: 4)
                        Text("\(Int(style.padding)) px").monospacedDigit()
                            .foregroundStyle(Color(nsColor: preferences.palette.secondary))
                    }.frame(height: 26)
                    ThemedSlider(title: L("留白"), value: $style.padding, range: 0...160,
                                 tickCount: RimvaCore.BackgroundStyle.paddingPresets.count, onEditingChanged: onEditingChanged)
                        .frame(height: 20)
                        .help(compact ? L("%@（%@）", L("留白"), "⇧↑ / ⇧↓") : L("留白"))
                }.frame(maxWidth: .infinity).disabled(!style.enabled)
                VStack(spacing: 4) {
                    toggleRow(L("截图圆角"), isOn: $style.rounded)
                    ThemedSlider(title: L("截图圆角"), value: $style.radius, range: 0...40, onEditingChanged: onEditingChanged)
                        .frame(height: 20).disabled(!style.rounded)
                        .help(compact ? L("%@（%@）", "\(Int(style.radius)) px", "⇧+ / ⇧−") : "\(Int(style.radius)) px")
                }.frame(maxWidth: .infinity)
            }
            VStack(spacing: 4) {
                HStack {
                    Text(L("背景圆角"))
                    Spacer(minLength: 4)
                    Text("\(Int(style.backgroundRadius)) px").monospacedDigit()
                        .foregroundStyle(Color(nsColor: preferences.palette.secondary))
                }.frame(height: 26)
                ThemedSlider(title: L("背景圆角"), value: $style.backgroundRadius, range: 0...80,
                             onEditingChanged: onEditingChanged)
                    .frame(height: 20)
            }.disabled(!style.enabled)
            VStack(spacing: 4) {
                HStack {
                    Text(L("截图不透明度"))
                    Spacer(minLength: 4)
                    Text("\(Int((style.contentOpacity * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(Color(nsColor: preferences.palette.secondary))
                }.frame(height: 26)
                ThemedSlider(title: L("截图不透明度"), value: Binding(
                    get: { style.contentOpacity * 100 },
                    set: { style.contentOpacity = $0 / 100 }
                ), range: 0...100, onEditingChanged: onEditingChanged)
                    .frame(height: 20)
            }
            HStack {
                Text(L("阴影"))
                Spacer(minLength: 12)
                ThemedSegments(selection: $style.shadow, values: ShadowStyle.allCases, equalWidth: false) { Text($0.title) }
                    .fixedSize().accessibilityLabel(L("阴影"))
            }.disabled(!style.enabled)
        }.controlSize(.small)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(ThemedToggleStyle())
        }.frame(maxWidth: .infinity, minHeight: 26)
    }
}

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
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: compact ? 96 : 112, maximum: 144), spacing: 14, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                appearanceSlot(.light)
                appearanceSlot(.dark)
            }
            ThemedSegments(selection: $source, values: BrowserSource.allCases) { Text($0.title) }
                .accessibilityLabel(L("背景来源"))
            switch source {
            case .presets: presets
            case .images: images
            case .folders: folders
            case .macOS: assets(library.wallpapers)
            }
            if let error = library.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Color(nsColor: palette.error))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color(nsColor: palette.text))
        .tint(Color(nsColor: palette.accentText))
        .onAppear {
            revealSource()
        }
        .onChange(of: style.source) { _, _ in revealSource() }
        .onChange(of: selectedPath) { _, _ in revealSource() }
        .onChange(of: previewAppearance) { _, _ in revealSource() }
    }

    private func revealSource() {
        if style.source == .preset { source = .presets }
        else {
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

    private func appearanceSlot(_ appearance: RenderAppearance) -> some View {
        let selected = previewAppearance == appearance
        let path = appearance == .light ? style.lightImagePath : style.darkImagePath
        let title = appearance == .light ? L("日间背景") : L("夜间背景")
        let otherPath = appearance == .light ? style.darkImagePath : style.lightImagePath
        let inherited = otherPath == nil ? L("未选择") : appearance == .dark ? L("沿用日间背景") : L("沿用夜间背景")
        let name = style.source == .preset ? style.customHex ?? style.preset.title
            : path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? inherited
        return Button { previewAppearance = appearance } label: {
            HStack(spacing: 10) {
                Image(systemName: appearance == .light ? "sun.max" : "moon")
                    .font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(Color(nsColor: selected ? palette.accentText : palette.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    // The panel heading already supplies “background”; keep narrow cards readable.
                    Text(compact ? (appearance == .light ? L("日间") : L("夜间")) : title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: selected ? palette.accentText : palette.text))
                    Text(name).font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: palette.secondary))
                }.lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(nsColor: selected ? palette.selection : palette.canvas), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: selected ? palette.accent : palette.separator), lineWidth: selected ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(path ?? title)
        .accessibilityLabel(title).accessibilityValue(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                            BackgroundThumbnail(url: preset.imageURL, background: palette.elevated)
                                .aspectRatio(1.5, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(selectionOutline(selected))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                Text(preset.variantTitle).foregroundStyle(Color(nsColor: palette.secondary))
                            }.font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: selected ? palette.accentText : palette.secondary))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(preset.title)
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
                                .foregroundStyle(Color(nsColor: selectedFolder == folder ? palette.accentText : palette.text))
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
                    VStack(alignment: .leading, spacing: 9) {
                        BackgroundThumbnail(url: asset.url, background: palette.elevated)
                            .aspectRatio(1.5, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(selectionOutline(selected))
                        Text(asset.name).font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: selected ? palette.accentText : palette.secondary))
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
            .strokeBorder(Color(nsColor: selected ? palette.accent : palette.separator), lineWidth: selected ? 2 : 0.5)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: "plus") }
            .buttonStyle(.plain).foregroundStyle(Color(nsColor: palette.secondaryAccent))
            .fixedSize()
    }

    private var customColor: Binding<Color> {
        Binding(get: {
            Color(nsColor: RimvaCore.ImageRenderer.color(hex: style.customHex ?? "#FAF4ED") ?? .white)
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
