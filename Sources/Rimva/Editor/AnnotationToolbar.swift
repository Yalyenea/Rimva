import AppKit
import SwiftUI
import RimvaCore

struct AnnotationToolbar: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var preferences = Preferences.shared

    // Annotation colors belong to the document and stay independent of the UI theme.
    private let colors = ["#F04444", "#F29D38", "#51A774", "#3578D8", "#9670CE", "#25272A"]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) {
                controls.fixedSize(horizontal: true, vertical: false)
            }.scrollIndicators(.hidden)
        }
        .frame(height: EditorToolbarMetrics.height)
        .background(Color(nsColor: preferences.palette.surface), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: preferences.palette.separator), lineWidth: 1))
    }

    private var controls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(colors, id: \.self) { hex in
                    Button { setColor(hex) } label: {
                        Circle().fill(Color(rimvaHex: hex))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color(nsColor: preferences.palette.separator), lineWidth: 0.5))
                            .frame(width: 24, height: 26)
                            .background(session.colorHex == hex ? Color(nsColor: preferences.palette.selection) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(session.colorHex == hex ? Color(nsColor: preferences.palette.accent) : .clear, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("标注颜色 %@", hex))
                    .accessibilityLabel(L("标注颜色 %@", hex))
                    .accessibilityAddTraits(session.colorHex == hex ? .isSelected : [])
                }
                CompactColorWell(color: Binding(get: {
                    ImageRenderer.color(hex: session.colorHex) ?? .black
                }, set: { color in
                    if let hex = color.rgbHex { setColor(hex) }
                }))
                .frame(width: 24, height: 26)
                .help(L("标注颜色"))
                .accessibilityLabel(L("标注颜色"))
            }

            if session.tool == .text || session.selected?.kind == .text {
                separator
                ThemedSegments(selection: Binding(get: { session.fontSize }, set: { size in
                    guard session.fontSize != size else { return }
                    session.fontSize = size
                    session.updateSelected { $0.fontSize = size }
                }), values: [24.0, 32.0, 48.0]) { Text("\(Int($0))") }
                    .frame(width: 104).accessibilityLabel(L("字号"))
            } else if session.tool == .arrow || session.tool == .rectangle || session.selected?.kind == .arrow || session.selected?.kind == .rectangle {
                separator
                HStack(spacing: 2) {
                    widthButton(3, title: "细")
                    widthButton(6, title: "中")
                    widthButton(10, title: "粗")
                }
            }

            if session.selectedID != nil {
                separator
                IconButton(title: L("删除标注"), symbol: "trash", action: session.deleteSelected)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: EditorToolbarMetrics.height)
        .font(.system(size: 12))
    }

    private var separator: some View {
        Rectangle().fill(Color(nsColor: preferences.palette.separator))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 6)
    }

    private func widthButton(_ width: Double, title: String) -> some View {
        Button {
            guard session.lineWidth != width else { return }
            session.lineWidth = width
            session.updateSelected { $0.lineWidth = width }
        } label: {
            Capsule()
                .fill(Color(nsColor: session.lineWidth == width ? preferences.palette.accent : preferences.palette.text))
                .frame(width: 15, height: width)
                .frame(width: 26, height: 26)
                .background(session.lineWidth == width ? Color(nsColor: preferences.palette.selection) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(title))
        .accessibilityLabel(L(title))
        .accessibilityAddTraits(session.lineWidth == width ? .isSelected : [])
    }

    private func setColor(_ hex: String) {
        guard session.colorHex != hex else { return }
        session.colorHex = hex
        session.updateSelected { $0.colorHex = hex }
    }
}

/// Explicit native bounds keep the color well from negotiating a larger SwiftUI size.
struct CompactColorWell: NSViewRepresentable {
    @Binding var color: NSColor
    var title: String = L("标注颜色")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WellContainer {
        let view = WellContainer()
        view.well.target = context.coordinator
        view.well.action = #selector(Coordinator.changeColor(_:))
        view.well.color = color
        return view
    }

    func updateNSView(_ nsView: WellContainer, context: Context) {
        context.coordinator.parent = self
        if nsView.well.color != color { nsView.well.color = color }
        nsView.well.toolTip = title
        nsView.well.setAccessibilityLabel(title)
    }

    static func dismantleNSView(_ nsView: WellContainer, coordinator: Coordinator) {
        nsView.well.deactivate()
    }

    final class Coordinator: NSObject {
        var parent: CompactColorWell
        init(_ parent: CompactColorWell) { self.parent = parent }
        @objc func changeColor(_ sender: NSColorWell) { parent.color = sender.color }
    }

    final class WellContainer: NSView {
        let well = HiddenColorWell(frame: .zero)
        private let button = ColorPanelButton(frame: .zero)
        override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 26) }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            well.colorWellStyle = .minimal
            well.supportsAlpha = false
            well.isContinuous = true
            // The native well owns the panel binding; the plain button avoids its minimum bezel size.
            well.isHidden = true
            well.setAccessibilityElement(false)
            well.onTitleChanged = { [weak self] title in
                guard let self else { return }
                button.toolTip = title
                button.setAccessibilityLabel(title)
                button.contentTintColor = Preferences.shared.palette.text
            }
            well.toolTip = L("标注颜色")
            addSubview(well)

            button.setButtonType(.momentaryPushIn)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            button.focusRingType = .exterior
            button.target = self
            button.action = #selector(openColorPanel(_:))
            addSubview(button)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            button.frame = bounds
        }

        // A click anywhere in the slot uses the same native color panel.
        override func mouseDown(with event: NSEvent) { openColorPanel(nil) }

        @objc private func openColorPanel(_ sender: Any?) {
            well.activate(true)
            NSColorPanel.shared.isContinuous = true
            NSColorPanel.shared.makeKeyAndOrderFront(nil)
        }

        final class HiddenColorWell: NSColorWell {
            var onTitleChanged: ((String) -> Void)?
            override var toolTip: String? {
                didSet { onTitleChanged?(toolTip ?? "") }
            }
        }

        final class ColorPanelButton: NSButton {
            override var acceptsFirstResponder: Bool { true }
            override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 26) }

            override func mouseDown(with event: NSEvent) {
                window?.makeFirstResponder(self)
                super.mouseDown(with: event)
            }

            override func keyDown(with event: NSEvent) {
                if event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" {
                    performClick(nil)
                } else {
                    super.keyDown(with: event)
                }
            }
        }
    }
}
