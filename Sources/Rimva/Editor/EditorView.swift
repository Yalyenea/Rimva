import AppKit
import SwiftUI
import RimvaCore
import UniformTypeIdentifiers

enum EditorToolbarMetrics {
    static let height: CGFloat = 34
    static let buttonSide: CGFloat = 26
}

final class EditorWindow: NSWindow {
    weak var session: EditorSession?

    override func sendEvent(_ event: NSEvent) {
        // The window receives letters even before a canvas click gives it focus.
        // Text entry and modified menu commands keep their normal event handling.
        guard event.type == .keyDown, let session, session.image != nil,
              attachedSheet == nil, !(firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.sendEvent(event)
            return
        }
        if let tool = EditorTool.allCases.first(where: { $0.shortcut == key }) {
            session.selectTool(tool)
        } else if key == "b" {
            session.backgroundShown.toggle()
        } else {
            super.sendEvent(event)
        }
    }
}

extension Color {
    init(rimvaHex hex: String) { self.init(nsColor: ImageRenderer.color(hex: hex) ?? .labelColor) }
    @MainActor static var rimvaCanvas: Color { Color(nsColor: Preferences.shared.palette.canvas) }
    @MainActor static var rimvaSurface: Color { Color(nsColor: Preferences.shared.palette.surface) }
}

struct IconButton: View {
    @ObservedObject private var preferences = Preferences.shared
    @State private var hovered = false
    let title: String
    let symbol: String
    var shortcut: String? = nil
    var active = false
    var primary = false
    var action: () -> Void
    private var help: String { shortcut.map { L("%@（%@）", title, $0) } ?? title }
    var body: some View {
        Button {
            hovered = false
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                // Keep typographic SF Symbols as the same pictogram in both languages.
                .environment(\.locale, Locale(identifier: "en"))
                .frame(width: EditorToolbarMetrics.buttonSide, height: EditorToolbarMetrics.buttonSide)
                .foregroundStyle(Color(nsColor: primary ? preferences.palette.onAccent : active ? preferences.palette.accent : preferences.palette.text))
                .background(primary ? Color(nsColor: preferences.palette.accent) : active ? Color(nsColor: preferences.palette.selection) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .anchorPreference(key: IconHelpKey.self, value: .bounds) { anchor in
            hovered ? IconHelp(text: help, anchor: anchor) : nil
        }
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

private struct IconHelp {
    let text: String
    let anchor: Anchor<CGRect>
}

private enum IconHelpKey: PreferenceKey {
    static var defaultValue: IconHelp? { nil }
    static func reduce(value: inout IconHelp?, nextValue: () -> IconHelp?) {
        value = nextValue() ?? value
    }
}

private struct IconHelpBubble: View {
    @ObservedObject private var preferences = Preferences.shared
    let text: String
    let target: CGRect
    let containerSize: CGSize
    @State private var visible = false

    var body: some View {
        let textSize = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
        let width = min(ceil(textSize.width) + 16, max(0, containerSize.width - 16))
        let height = ceil(textSize.height) + 10
        let x = min(max(8, target.midX - width / 2), containerSize.width - width - 8)
        let below = target.maxY + 6
        let y = below + height <= containerSize.height - 8 ? below : target.minY - height - 6

        Text(text)
            .font(.system(size: 11)).lineLimit(1)
            .foregroundStyle(Color(nsColor: preferences.palette.text))
            .frame(width: width, height: height)
            .background(Color(nsColor: preferences.palette.surface), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: preferences.palette.separator), lineWidth: 1))
            .position(x: x + width / 2, y: y + height / 2)
            .opacity(visible ? 1 : 0)
            .task(id: text) {
                visible = false
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                visible = true
            }
    }
}

struct EditorView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var preferences = Preferences.shared
    let controller: AppController
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color(nsColor: preferences.palette.separator)).frame(height: 0.5)
            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Color.rimvaCanvas
                    if session.image != nil {
                        CanvasView(session: session, onImport: controller.importImage, onPaste: controller.pasteImage)
                        if session.tool != .select || session.selectedID != nil { contextTools.padding(.top, 12) }
                        VStack {
                            Spacer()
                            HStack(spacing: 5) {
                                if session.clipboardIsStale {
                                    Button(L("重新复制"), action: controller.copyImage)
                                        .font(.system(size: 11)).lineLimit(1).fixedSize()
                                        .buttonStyle(.plain).foregroundStyle(Color(nsColor: preferences.palette.accent))
                                        .padding(.horizontal, 8).frame(height: 26)
                                        .background(Color.rimvaSurface, in: RoundedRectangle(cornerRadius: 6))
                                        .help(L("编辑已更改，重新复制"))
                                }
                                Spacer(minLength: 4)
                                viewportControls.fixedSize(horizontal: true, vertical: true)
                            }.padding(10)
                        }
                    } else { emptyState }
                    if let toast = session.toast {
                        VStack { Spacer(); Text(toast).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 18) }
                            .allowsHitTesting(false)
                    }
                }
                if session.backgroundShown, session.image != nil {
                    Rectangle().fill(Color(nsColor: preferences.palette.separator)).frame(width: 0.5)
                    VStack(spacing: 0) {
                        HStack {
                            Text(L("背景外观")).font(.system(size: 12, weight: .medium))
                            Spacer()
                            IconButton(title: L("关闭"), symbol: "xmark") { session.backgroundShown = false }
                        }.padding(.horizontal, 12).frame(height: 34)
                        BackgroundPanel(session: session)
                    }.frame(width: 344)
                }
            }
        }
        .background(Color.rimvaSurface)
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .tint(Color(nsColor: preferences.palette.accent))
        .ignoresSafeArea()
        .environment(\.locale, L10n.locale)
        .id(preferences.language)
        // Draw above the whole editor so the canvas cannot cover tooltips, and
        // keep their placement within the window for tools near any edge.
        .overlayPreferenceValue(IconHelpKey.self) { help in
            GeometryReader { geometry in
                if let help {
                    IconHelpBubble(text: help.text, target: geometry[help.anchor], containerSize: geometry.size)
                        .id(help.text)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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
                    IconButton(title: tool.title, symbol: tool.symbol, shortcut: tool.shortcut.uppercased(), active: session.tool == tool) { session.selectTool(tool) }
                }
            }.disabled(session.image == nil)
            divider
            IconButton(title: L("撤销"), symbol: "arrow.uturn.backward", shortcut: "⌘Z", action: session.undo).disabled(!session.canUndo)
            IconButton(title: L("重做"), symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", action: session.redo).disabled(!session.canRedo)
            divider
            IconButton(title: L("背景外观"), symbol: "rectangle.split.2x2", shortcut: "B", active: session.backgroundShown) { session.backgroundShown.toggle() }
                .disabled(session.image == nil)
            WindowDragArea().frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
            IconButton(title: L("截图入口"), symbol: "viewfinder", action: controller.showCaptureLauncher)
            IconButton(title: L("设置"), symbol: "slider.horizontal.3", shortcut: "⌘,", action: controller.showSettings)
            IconButton(title: L("保存"), symbol: "square.and.arrow.down", shortcut: "⌘S", action: controller.saveImage).disabled(session.image == nil)
                .contextMenu {
                    Button(L("另存为…"), action: controller.saveImageAs)
                    Button(L("在访达中显示"), action: controller.revealSavedImage).disabled(session.savedURL == nil)
                }
            IconButton(title: L("复制成图"), symbol: "square.on.square", shortcut: "⌘↵", primary: true, action: controller.copyImage).disabled(session.image == nil)
        }.padding(.horizontal, 10).frame(height: EditorToolbarMetrics.height).background(Color.rimvaSurface)
    }
    private var divider: some View { Rectangle().fill(Color(nsColor: preferences.palette.separator)).frame(width: 1, height: 14).padding(.horizontal, 4) }
    private var viewportControls: some View {
        HStack(spacing: 1) {
            Text("\(Int(session.outputSize.width)) × \(Int(session.outputSize.height)) px")
                .monospacedDigit().lineLimit(1).padding(.horizontal, 7)
                .help(L("输出尺寸；复制和保存使用当前成图"))
            IconButton(title: L("缩小"), symbol: "minus.magnifyingglass") { session.zoom = max(0.05, session.displayedZoom / 1.25) }
            Text("\(Int((session.displayedZoom * 100).rounded()))%")
                .monospacedDigit().frame(minWidth: 35)
            IconButton(title: L("放大"), symbol: "plus.magnifyingglass") { session.zoom = min(8, max(0.05, session.displayedZoom * 1.25)) }
            IconButton(title: L("实际尺寸"), symbol: "1.magnifyingglass") { session.zoom = 1 }
            IconButton(title: L("适应窗口"), symbol: "arrow.down.right.and.arrow.up.left") { session.zoom = nil }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
        .background(Color.rimvaSurface, in: RoundedRectangle(cornerRadius: 6))
        .help(L("滚轮平移；⌘ 滚轮或双指捏合缩放；⌥ 拖动平移"))
    }
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
                sliderRow("留白", value: $session.style.padding, range: 0...160).disabled(!session.style.enabled)
                HStack {
                    Text(L("圆角"))
                    Spacer()
                    Toggle(L("添加圆角"), isOn: style.rounded).labelsHidden().toggleStyle(ThemedToggleStyle(compact: true))
                }
                sliderRow("半径", value: $session.style.radius, range: 0...40).disabled(!session.style.rounded)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L("阴影"))
                        Spacer()
                        ThemedSegments(selection: style.shadow, values: ShadowStyle.allCases) { value in
                            Text(value.title)
                        }.frame(width: 196).accessibilityLabel(L("阴影"))
                    }
                    toggleRow("跟随外观", isOn: style.followsAppearance)
                    Rectangle().fill(Color(nsColor: preferences.palette.separator)).frame(height: 0.5)
                    BackgroundBrowser(style: style, previewAppearance: $previewAppearance, compact: true)
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
                if editing { session.beginInteraction() } else { session.endInteraction() }
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
