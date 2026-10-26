import AppKit
import Combine
import RimvaCore
import SwiftUI

@MainActor
final class CaptureLauncher: NSObject, NSWindowDelegate {
    var isVisible: Bool { panel?.isVisible == true }

    private var panel: LauncherPanel?
    private var choose: ((CaptureMode) -> Void)?
    private var openEditor: (() -> Void)?
    private var keyMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []

    func show(on screen: NSScreen?, openEditor: @escaping () -> Void, choose: @escaping (CaptureMode) -> Void) {
        close()
        self.choose = choose
        self.openEditor = openEditor
        let size = NSSize(width: 706, height: 104)
        let panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Match the selection overlay so floating windows and menus cannot cover the launcher.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = Preferences.shared.appearance.native
        panel.title = L("截图入口")
        panel.delegate = self
        let content = CaptureLauncherView(choose: { [weak self] mode in self?.select(mode) },
                                          openEditor: { [weak self] in self?.edit() })
        panel.contentView = NSHostingView(rootView: content.ignoresSafeArea())
        let target = screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let visibleFrame = target?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2))
        } else {
            panel.center()
        }
        self.panel = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 53: self.close(); return nil
            case 18, 83, 36, 76: self.select(.region); return nil
            case 19, 84: self.select(.scrolling); return nil
            case 20, 85: self.select(.window); return nil
            case 21, 86: self.select(.fullScreen); return nil
            case 23, 87: self.edit(); return nil
            default: return event
            }
        }
        NotificationCenter.default.publisher(for: .rimvaThemeChanged)
            .sink { [weak self] _ in self?.panel?.appearance = Preferences.shared.appearance.native }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .rimvaLanguageChanged)
            .sink { [weak self] _ in self?.panel?.title = L("截图入口") }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &subscriptions)
        // A nonactivating panel accepts the choice without bringing editor windows forward.
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        choose = nil
        openEditor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        subscriptions.removeAll()
        let closingPanel = panel
        panel = nil
        closingPanel?.delegate = nil
        closingPanel?.orderOut(nil)
        closingPanel?.contentView = nil
        closingPanel?.close()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func edit() {
        guard let openEditor else { return }
        close()
        openEditor()
    }

    private func select(_ mode: CaptureMode) {
        guard let choose else { return }
        close()
        // Let AppKit remove the panel before ScreenCaptureKit freezes any display.
        DispatchQueue.main.async { choose(mode) }
    }
}

@MainActor
private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct CaptureLauncherView: View {
    var choose: (CaptureMode) -> Void
    var openEditor: () -> Void
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        let palette = preferences.palette
        HStack(spacing: 8) {
            option(L("区域截图"), icon: "viewfinder", key: "1") { choose(.region) }
            option(L("长截屏"), icon: "arrow.down.to.line.compact", key: "2") { choose(.scrolling) }
            option(L("窗口截图"), icon: "macwindow", key: "3") { choose(.window) }
            option(L("全屏截图"), icon: "rectangle.dashed", key: "4") { choose(.fullScreen) }
            option(L("打开编辑器"), icon: "square.and.pencil", key: "5", action: openEditor)
        }
        .padding(12)
        .foregroundStyle(Color(nsColor: palette.text))
        .background(Color(nsColor: palette.background), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color(nsColor: palette.separator), lineWidth: 0.5)
        }
        .environment(\.locale, L10n.locale)
    }

    private func option(_ title: String, icon: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 20, weight: .regular))
                    Spacer(minLength: 4)
                    Text(key).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(nsColor: preferences.palette.secondary))
                }
                Text(title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(LauncherOptionStyle())
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .accessibilityHint(key)
    }
}

private struct LauncherOptionStyle: ButtonStyle {
    @ObservedObject private var preferences = Preferences.shared
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(nsColor: configuration.isPressed || hovered ? preferences.palette.selection : preferences.palette.elevated),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: hovered ? preferences.palette.accent : preferences.palette.separator), lineWidth: 0.5)
            }
            .onHover { hovered = $0 }
    }
}
