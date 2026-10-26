import AppKit
import Carbon
import Combine
import RimvaCore
import SwiftUI

@MainActor
final class CaptureLauncher: NSObject {
    var isVisible: Bool { panel?.isVisible == true }

    private var panel: LauncherPanel?
    private var choose: ((CaptureMode) -> Void)?
    private var openEditor: (() -> Void)?
    private var openSettings: (() -> Void)?
    private let keys = CaptureKeySession(signature: 0x52494D4C)
    private var mouseMonitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []

    func show(on screen: NSScreen?, openSettings: @escaping () -> Void, openEditor: @escaping () -> Void,
              choose: @escaping (CaptureMode) -> Void) throws {
        close()
        try keys.start([18, 19, 20, 21, 23, 22, 83, 84, 85, 86, 87, 88, 36, 76, 53]) { [weak self] in self?.handleShortcut($0) }
        self.choose = choose
        self.openEditor = openEditor
        self.openSettings = openSettings
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
        let content = CaptureLauncherView(choose: { [weak self] mode in self?.select(mode) },
                                          openEditor: { [weak self] in self?.edit() },
                                          openSettings: { [weak self] in self?.settings() })
        panel.contentView = NSHostingView(rootView: content.ignoresSafeArea())
        let target = screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let visibleFrame = target?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2))
        } else {
            panel.center()
        }
        self.panel = panel
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            if let self, event.window !== self.panel { self.close() }
            return event
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] _ in
            self?.close()
        }) { mouseMonitors.append(monitor) }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard notification.userInfo?[NSWorkspace.applicationUserInfoKey] is NSRunningApplication else { return }
                self?.close()
            }
            .store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .rimvaThemeChanged)
            .sink { [weak self] _ in self?.panel?.appearance = Preferences.shared.appearance.native }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .rimvaLanguageChanged)
            .sink { [weak self] _ in self?.panel?.title = L("截图入口") }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &subscriptions)
        // Even a nonactivating key panel steals keyboard focus and dismisses system popovers.
        // Scoped hotkeys accept the choice while the original window keeps its focus.
        panel.orderFrontRegardless()
    }

    func close() {
        choose = nil
        openEditor = nil
        openSettings = nil
        keys.stop()
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        subscriptions.removeAll()
        let closingPanel = panel
        panel = nil
        closingPanel?.orderOut(nil)
        closingPanel?.contentView = nil
        closingPanel?.close()
    }

    deinit {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    private func handleShortcut(_ key: UInt32) {
        guard isVisible else { return }
        switch key {
        case 53: close()
        case 18, 83, 36, 76: select(.region)
        case 19, 84: select(.scrolling)
        case 20, 85: select(.window)
        case 21, 86: select(.fullScreen)
        case 23, 87: edit()
        case 22, 88: settings()
        default: break
        }
    }

    private func edit() {
        guard let openEditor else { return }
        close()
        openEditor()
    }

    private func settings() {
        guard let openSettings else { return }
        close()
        openSettings()
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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CaptureLauncherView: View {
    var choose: (CaptureMode) -> Void
    var openEditor: () -> Void
    var openSettings: () -> Void
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        let palette = preferences.palette
        HStack(spacing: 8) {
            option(L("区域截图"), icon: "viewfinder", key: "1") { choose(.region) }
            option(L("长截屏"), icon: "arrow.down.to.line.compact", key: "2") { choose(.scrolling) }
            option(L("窗口截图"), icon: "macwindow", key: "3") { choose(.window) }
            option(L("全屏截图"), icon: "rectangle.dashed", key: "4") { choose(.fullScreen) }
            VStack(spacing: 6) {
                Button(action: openEditor) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil").font(.system(size: 16))
                        Text(L("打开编辑器")).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        shortcut("5")
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LauncherOptionStyle())
                .accessibilityLabel(L("打开编辑器"))
                .accessibilityHint("5")
                Button(action: openSettings) {
                    HStack(spacing: 7) {
                        Image(systemName: "gearshape").font(.system(size: 12))
                        Text(L("设置")).font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 4)
                        shortcut("6")
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LauncherOptionStyle())
                .help(L("设置…") + " (6)")
                .accessibilityLabel(L("设置…"))
                .accessibilityHint("6")
            }
            .frame(width: 130)
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

    private func shortcut(_ key: String) -> some View {
        Text(key).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(nsColor: preferences.palette.secondary))
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
