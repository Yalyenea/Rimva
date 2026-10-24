import AppKit
import Combine
import SwiftUI
import RimvaCore
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let session = EditorSession()
    let preferences = Preferences.shared
    let hotKey = HotKey()
    private let capture = CaptureCoordinator()
    private let captureLauncher = CaptureLauncher()
    private var editorWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var capturePending = false
    private var languageSubscription: AnyCancellable?
    private var themeSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = preferences.appearance.native
        buildMenus()
        languageSubscription = NotificationCenter.default.publisher(for: .rimvaLanguageChanged).sink { [weak self] _ in
            self?.buildMenus()
            self?.settingsWindow?.title = L("Rimva 设置")
            // SwiftUI recreates the editor content when its language changes.
            DispatchQueue.main.async { self?.alignEditorWindowControls() }
        }
        themeSubscription = NotificationCenter.default.publisher(for: .rimvaThemeChanged).sink { [weak self] _ in
            guard let self else { return }
            for window in [self.editorWindow, self.settingsWindow].compactMap({ $0 }) {
                window.backgroundColor = self.preferences.palette.background
                window.contentView?.needsDisplay = true
            }
        }
        capture.onCapture = { [weak self] image in
            guard let self else { return }
            self.session.load(image); self.showEditor(); self.preferences.refreshSystemStatus()
            if self.preferences.automaticCopy {
                do { try ImageExporter.copy(self.renderedImage(image)) }
                catch { self.showError(error) }
            }
        }
        capture.onCancel = { [weak self] in self?.showEditor() }
        capture.onError = { [weak self] error in
            guard let self else { return }
            self.showEditor(); self.preferences.refreshSystemStatus(); self.showError(error, captureFailure: true)
        }
        hotKey.onTrigger = { [weak self] action in
            guard let self else { return }
            let mode: CaptureMode
            switch action {
            case .launcher: self.showCaptureLauncher(); return
            case .area: mode = .region
            case .window: mode = .window
            case .fullScreen: mode = .fullScreen
            case .scrolling: mode = .scrolling
            }
            self.startCapture(mode)
        }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo"), let image = SampleImage.make() { session.load(image) }
        if let index = arguments.firstIndex(of: "--image"), arguments.indices.contains(index + 1) { importImage(URL(fileURLWithPath: arguments[index + 1])) }
        showEditor()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showEditor(); return true }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool { importImage(URL(fileURLWithPath: filename)); return true }

    func showEditor() {
        if editorWindow == nil {
            let window = makeWindow(size: CGSize(width: 1008, height: 650), title: "Rimva", resizable: true)
            window.minSize = CGSize(width: 800, height: 520)
            let hosting = NSHostingView(rootView: EditorView(session: session, controller: self))
            // Localization changes text lengths, never the user's window size.
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: 1008, height: 650)), display: false)
            window.center()
            window.delegate = self
            editorWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
        editorWindow?.makeFirstResponder(nil)
        alignEditorWindowControls()
        DispatchQueue.main.async { [weak self] in self?.alignEditorWindowControls() }
    }

    func showSettings() {
        preferences.refreshSystemStatus()
        if settingsWindow == nil {
            let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
            let size = CGSize(width: min(940, available.width), height: min(700, available.height))
            let window = makeWindow(size: size, title: L("Rimva 设置"), resizable: true)
            window.minSize = CGSize(width: min(680, available.width), height: min(420, available.height))
            let hosting = NSHostingView(rootView: SettingsView(preferences: preferences, hotKey: hotKey))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setFrame(CGRect(origin: window.frame.origin, size: size), display: false)
            window.center()
            window.setFrameAutosaveName("RimvaSettings")
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.makeFirstResponder(nil)
    }

    private func makeWindow(size: CGSize, title: String, resizable: Bool) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.backgroundColor = preferences.palette.background
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === editorWindow { session.releaseImage() }
    }

    func windowDidResize(_ notification: Notification) {
        if (notification.object as? NSWindow) === editorWindow { alignEditorWindowControls() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === editorWindow { alignEditorWindowControls() }
    }

    private func alignEditorWindowControls() {
        guard let content = editorWindow?.contentView else { return }
        // Native window controls retain their own actions and hit areas, while
        // their centers follow the same compact row as the SwiftUI tool icons.
        let centerY = content.isFlipped ? EditorToolbarMetrics.height / 2 : content.bounds.height - EditorToolbarMetrics.height / 2
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = editorWindow?.standardWindowButton(type), let container = button.superview else { continue }
            let center = content.convert(CGPoint(x: 0, y: centerY), to: container)
            button.setFrameOrigin(CGPoint(x: button.frame.minX, y: center.y - button.frame.height / 2))
        }
    }

    func startCapture(_ mode: CaptureMode) {
        guard !capturePending, !capture.isCapturing else { return }
        captureLauncher.close()
        capturePending = true
        editorWindow?.orderOut(nil); settingsWindow?.orderOut(nil)
        // Let WindowServer finish hiding our windows before freezing the desktop.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self else { return }
            self.capturePending = false
            self.capture.start(mode, includesCursor: self.preferences.includesCursor)
        }
    }

    func showCaptureLauncher() {
        guard !capturePending, !capture.isCapturing else { return }
        if captureLauncher.isVisible { captureLauncher.close(); return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        captureLauncher.show(on: screen) { [weak self] in self?.startCapture($0) }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = L("导入图片")
        panel.prompt = L("导入")
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importImage(url) }
    }

    func importImage(_ url: URL) {
        do { session.load(try ImageExporter.read(url)); showEditor() }
        catch { showError(error) }
    }

    func pasteImage() {
        let board = NSPasteboard.general
        if let url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first { importImage(url); return }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff),
           let image = NSBitmapImageRep(data: data)?.cgImage { session.load(image); showEditor(); return }
        session.notify(L("剪贴板中没有图片。"))
    }

    func copyImage() {
        guard let image = session.image else { return }
        do {
            editorWindow?.makeFirstResponder(nil)
            try ImageExporter.copy(renderedImage(image))
            editorWindow?.close()
        } catch { showError(error) }
    }

    func saveImage() {
        guard let image = session.image else { return }
        do {
            editorWindow?.makeFirstResponder(nil)
            let rendered = try renderedImage(image)
            let url = try ImageExporter.save(rendered, to: preferences.saveFolder)
            preferences.lastSavedURL = url
            session.notify(L("已保存到 %@", preferences.saveFolder.lastPathComponent))
        } catch { showError(error) }
    }

    private func renderedImage(_ image: CGImage) throws -> CGImage {
        try ImageRenderer.render(image: image, state: session.state, style: session.style,
                                 appearance: preferences.renderAppearance)
    }

    private func showError(_ error: Error, captureFailure: Bool = false) {
        let alert = NSAlert()
        alert.messageText = L("操作未完成")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if captureFailure && !CaptureCoordinator.permissionGranted {
            alert.addButton(withTitle: L("打开系统设置"))
            alert.addButton(withTitle: L("稍后"))
            if alert.runModal() == .alertFirstButtonReturn { CaptureCoordinator.openPermissionSettings() }
        } else {
            alert.addButton(withTitle: L("关闭"))
            if let window = editorWindow, window.isVisible { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
    }

    private func buildMenus() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(item("设置…", action: #selector(settingsAction), key: ","))
        app.addItem(.separator())
        app.addItem(item("退出 Rimva", action: #selector(quitAction), key: "q"))
        let appRoot = NSMenuItem(); appRoot.submenu = app; main.addItem(appRoot)
        let file = NSMenu(title: L("文件"))
        file.addItem(item("截图入口", action: #selector(captureAction)))
        file.addItem(item("区域截图", action: #selector(regionAction)))
        file.addItem(item("窗口截图", action: #selector(windowAction)))
        file.addItem(item("全屏截图", action: #selector(fullScreenAction)))
        file.addItem(item("长截屏", action: #selector(scrollingAction)))
        file.addItem(.separator())
        file.addItem(item("导入图片…", action: #selector(importAction), key: "o"))
        file.addItem(item("保存 PNG", action: #selector(saveAction), key: "s"))
        file.addItem(item("复制成图", action: #selector(copyAction), key: "\r"))
        file.addItem(item("关闭窗口", action: #selector(closeAction), key: "w"))
        let fileRoot = NSMenuItem(title: L("文件"), action: nil, keyEquivalent: ""); fileRoot.submenu = file; main.addItem(fileRoot)
        let edit = NSMenu(title: L("编辑"))
        let undo = NSMenuItem(title: L("撤销"), action: #selector(undo(_:)), keyEquivalent: "z"); edit.addItem(undo)
        let redo = NSMenuItem(title: L("重做"), action: #selector(redo(_:)), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("粘贴"), action: #selector(paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editRoot = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: ""); editRoot.submenu = edit; main.addItem(editRoot)
        NSApp.mainMenu = main

        let status = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Rimva")
        status.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.addItem(item("截图入口", action: #selector(captureAction)))
        menu.addItem(item("区域截图", action: #selector(regionAction)))
        menu.addItem(item("窗口截图", action: #selector(windowAction)))
        menu.addItem(item("全屏截图", action: #selector(fullScreenAction)))
        menu.addItem(item("长截屏", action: #selector(scrollingAction)))
        menu.addItem(.separator())
        menu.addItem(item("导入图片…", action: #selector(importAction)))
        menu.addItem(item("打开编辑器", action: #selector(editorAction)))
        menu.addItem(item("设置…", action: #selector(settingsAction)))
        menu.addItem(.separator())
        menu.addItem(item("退出 Rimva", action: #selector(quitAction)))
        status.menu = menu; statusItem = status
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: L(title), action: action, keyEquivalent: key); result.target = self; return result
    }
    @objc private func regionAction() { startCapture(.region) }
    @objc private func captureAction() { showCaptureLauncher() }
    @objc private func scrollingAction() { startCapture(.scrolling) }
    @objc private func windowAction() { startCapture(.window) }
    @objc private func fullScreenAction() { startCapture(.fullScreen) }
    @objc private func editorAction() { showEditor() }
    @objc private func settingsAction() { showSettings() }
    @objc private func importAction() { chooseImage() }
    @objc private func saveAction() { saveImage() }
    @objc private func copyAction() { copyImage() }
    @objc private func closeAction() { NSApp.keyWindow?.close() }
    @objc private func quitAction() { captureLauncher.close(); capture.cancel(); NSApp.terminate(nil) }
    @objc func paste(_ sender: Any?) { pasteImage() }
    @objc func undo(_ sender: Any?) { session.undo() }
    @objc func redo(_ sender: Any?) { session.redo() }
}
