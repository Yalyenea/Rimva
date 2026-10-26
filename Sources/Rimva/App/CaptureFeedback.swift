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
        let size = NSSize(width: 204, height: 40)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
        panel.contentView = FeedbackHostingView(rootView: CaptureFeedbackView(message: message, edit: { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.close()
            edit()
        }, hover: { [weak self, weak panel] hovering in
            guard let self, let panel, self.panel === panel else { return }
            self.dismissTask?.cancel()
            if !hovering { self.scheduleDismissal() }
        }))
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
        HStack(spacing: 7) {
            Image(systemName: "checkmark").foregroundStyle(Color(nsColor: preferences.palette.accent))
            Text(message)
            Spacer(minLength: 12)
            Button(action: edit) {
                Text(L("编辑"))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(nsColor: preferences.palette.elevated), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("在编辑器中打开"))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: preferences.palette.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: preferences.palette.separator), lineWidth: 0.5))
        .onHover(perform: hover)
    }
}
