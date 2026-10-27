import AppKit
import SwiftUI
import RimvaCore

@MainActor
final class CaptureFeedback {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(copied: Bool, edit: @escaping () -> Void) {
        close()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let message = copied ? L("已复制") : L("已保存")
        panel.title = message
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = Preferences.shared.appearance.native
        let content = FeedbackHostingView(rootView: CaptureFeedbackView(message: message, edit: { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.close()
            edit()
        }, hover: { [weak self, weak panel] hovering in
            guard let self, let panel, self.panel === panel else { return }
            self.dismissTask?.cancel()
            if !hovering { self.scheduleDismissal() }
        }))
        // Size to the localized controls instead of stretching a fixed-width toast.
        let size = content.fittingSize
        panel.contentView = content
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                     y: screen.visibleFrame.minY + 48))
        self.panel = panel
        // Quick capture may hide Rimva after returning to the original app.
        // Show feedback without reactivating Rimva or giving the panel focus.
        NSApp.unhideWithoutActivation()
        panel.orderFrontRegardless()
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        dismissTask?.cancel()
        dismissTask = nil
        let closingPanel = panel
        panel = nil
        closingPanel?.orderOut(nil)
        closingPanel?.close()
    }

    deinit {
        dismissTask?.cancel()
        let panel = panel
        Task { @MainActor in panel?.close() }
    }
}

private final class FeedbackHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CaptureFeedbackView: View {
    let message: String
    var edit: () -> Void
    var hover: (Bool) -> Void
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: preferences.palette.accent))
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(message)
            }
            Button(action: edit) {
                HStack(spacing: 5) {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .medium))
                    Text(L("编辑"))
                }
            }
            .buttonStyle(ThemedActionStyle())
            .help(L("在编辑器中打开"))
            .accessibilityLabel(L("在编辑器中打开"))
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .padding(.horizontal, 8)
        .frame(height: EditorToolbarMetrics.height)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(nsColor: preferences.palette.surface), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: preferences.palette.separator), lineWidth: 1))
        .focusEffectDisabled()
        .onHover(perform: hover)
    }
}
