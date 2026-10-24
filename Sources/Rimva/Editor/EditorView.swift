import AppKit
import SwiftUI
import RimvaCore
import UniformTypeIdentifiers

enum EditorToolbarMetrics {
    static let height: CGFloat = 34
    static let buttonSide: CGFloat = 26
}

extension Color {
    init(rimvaHex hex: String) { self.init(nsColor: ImageRenderer.color(hex: hex) ?? .labelColor) }
    @MainActor static var rimvaCanvas: Color { Color(nsColor: Preferences.shared.palette.canvas) }
    @MainActor static var rimvaSurface: Color { Color(nsColor: Preferences.shared.palette.surface) }
}

struct IconButton: View {
    @ObservedObject private var preferences = Preferences.shared
    let title: String
    let symbol: String
    var active = false
    var primary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                // Keep typographic SF Symbols as the same pictogram in both languages.
                .environment(\.locale, Locale(identifier: "en"))
                .frame(width: EditorToolbarMetrics.buttonSide, height: EditorToolbarMetrics.buttonSide)
                .foregroundStyle(Color(nsColor: primary ? preferences.palette.onAccent : active ? preferences.palette.accent : preferences.palette.text))
                .background(primary ? Color(nsColor: preferences.palette.accent) : active ? Color(nsColor: preferences.palette.selection) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct EditorView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var preferences = Preferences.shared
    let controller: AppController
    @State private var backgroundShown = false
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color(nsColor: preferences.palette.separator)).frame(height: 0.5)
            ZStack(alignment: .top) {
                Color.rimvaCanvas
                if session.image != nil {
                    CanvasView(session: session, onImport: controller.importImage, onPaste: controller.pasteImage)
                    if session.tool != .select || session.selectedID != nil { contextTools.padding(.top, 12) }
                } else { emptyState }
                if let toast = session.toast {
                    VStack { Spacer(); Text(toast).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 18) }
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color.rimvaSurface)
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .tint(Color(nsColor: preferences.palette.accent))
        .ignoresSafeArea()
        .environment(\.locale, L10n.locale)
        .id(preferences.language)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { controller.importImage(url) }
            }
            return true
        }
    }
    private var toolbar: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 66, height: EditorToolbarMetrics.height)
            HStack(spacing: 1) {
                ForEach(EditorTool.allCases) { tool in
                    IconButton(title: tool.title, symbol: tool.symbol, active: session.tool == tool) { session.selectTool(tool) }
                }
            }.disabled(session.image == nil)
            divider
            IconButton(title: L("撤销") + " ⌘ Z", symbol: "arrow.uturn.backward", action: session.undo).disabled(!session.canUndo)
            IconButton(title: L("重做") + " ⇧ ⌘ Z", symbol: "arrow.uturn.forward", action: session.redo).disabled(!session.canRedo)
            divider
            IconButton(title: L("背景外观"), symbol: "rectangle.split.2x2", active: backgroundShown) { backgroundShown.toggle() }
                .disabled(session.image == nil)
                .popover(isPresented: $backgroundShown, arrowEdge: .bottom) { BackgroundPanel(session: session).frame(width: 440, height: 540) }
            WindowDragArea().frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
            IconButton(title: L("截图入口"), symbol: "viewfinder", action: controller.showCaptureLauncher)
            IconButton(title: L("设置") + " ⌘ ,", symbol: "slider.horizontal.3", action: controller.showSettings)
            IconButton(title: L("保存") + " ⌘ S", symbol: "square.and.arrow.down", action: controller.saveImage).disabled(session.image == nil)
            IconButton(title: L("复制成图") + " ⌘ ↵", symbol: "square.on.square", primary: true, action: controller.copyImage).disabled(session.image == nil)
        }.padding(.horizontal, 10).frame(height: EditorToolbarMetrics.height).background(Color.rimvaSurface)
    }
    private var divider: some View { Rectangle().fill(Color(nsColor: preferences.palette.separator)).frame(width: 1, height: 14).padding(.horizontal, 4) }
    private var contextTools: some View {
        Group {
            if session.tool == .crop {
                HStack(spacing: 10) {
                    if let crop = session.pendingCrop { Text("\(Int(crop.width)) × \(Int(crop.height)) px").monospacedDigit().foregroundStyle(.secondary) }
                    Button(L("取消")) { session.selectTool(.select) }.buttonStyle(ThemedActionStyle())
                    Button(L("应用"), action: session.applyCrop).buttonStyle(ThemedActionStyle(prominent: true))
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: EditorToolbarMetrics.height)
                .background(Color.rimvaSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: preferences.palette.separator), lineWidth: 1))
            } else {
                AnnotationToolbar(session: session)
            }
        }.padding(.horizontal, 12)
    }
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "viewfinder").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(L("截取画面，留住重点")).font(.system(size: 18, weight: .medium))
            HStack(spacing: 12) {
                Button(L("开始截图"), action: controller.showCaptureLauncher).buttonStyle(ThemedActionStyle(prominent: true))
                Button(L("导入图片…"), action: controller.chooseImage).buttonStyle(ThemedActionStyle())
            }.controlSize(.regular)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BackgroundPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var preferences = Preferences.shared
    @State private var previewAppearance = RenderAppearance.light

    private var style: Binding<RimvaCore.BackgroundStyle> {
        Binding(get: { session.style }, set: { next in
            guard next != session.style else { return }
            session.changeStyle { $0 = next }
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toggleRow("背景", isOn: style.enabled)
                VStack(alignment: .leading, spacing: 16) {
                    sliderRow("留白", value: $session.style.padding, range: 0...160)
                    HStack {
                        Text(L("圆角"))
                        Spacer()
                        Toggle(L("添加圆角"), isOn: style.rounded).labelsHidden().toggleStyle(ThemedToggleStyle(compact: true))
                    }
                    sliderRow("半径", value: $session.style.radius, range: 0...40).disabled(!session.style.rounded)
                    HStack {
                        Text(L("阴影"))
                        Spacer()
                        ThemedSegments(selection: style.shadow, values: ShadowStyle.allCases) { value in
                            Text(value.title)
                        }.frame(width: 160).accessibilityLabel(L("阴影"))
                    }
                    toggleRow("跟随外观", isOn: style.followsAppearance)
                    Rectangle().fill(Color(nsColor: preferences.palette.separator)).frame(height: 0.5)
                    BackgroundBrowser(style: style, previewAppearance: $previewAppearance)
                }.disabled(!session.style.enabled)
            }.padding(18)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .tint(Color(nsColor: preferences.palette.accent))
        .background(Color(nsColor: preferences.palette.background))
        .onAppear { previewAppearance = preferences.renderAppearance }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(L(label))
            Spacer()
            Toggle(L(label), isOn: isOn).labelsHidden().toggleStyle(ThemedToggleStyle())
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(L(label))
                Spacer()
                Text("\(Int(value.wrappedValue)) px").foregroundStyle(Color(nsColor: preferences.palette.secondary)).monospacedDigit()
            }
            // One undo entry covers the entire slider drag.
            ThemedSlider(title: L(label), value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), range: range) { editing in
                if editing { session.checkpoint() }
            }.frame(height: 20)
        }
    }
}

extension NSColor {
    var rgbHex: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((color.redComponent*255).rounded()), Int((color.greenComponent*255).rounded()), Int((color.blueComponent*255).rounded()))
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
