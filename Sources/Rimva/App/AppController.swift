import AppKit
import Carbon
import Combine
import SwiftUI
import RimvaCore
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let session = EditorSession()
    let preferences = Preferences.shared
    let hotKey: HotKey
    private let capture = CaptureCoordinator()
    private let captureLauncher = CaptureLauncher()
    private var editorWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var capturePending = false
    private var languageSubscription: AnyCancellable?
    private var menuBarSubscription: AnyCancellable?
    private var themeSubscription: AnyCancellable?
    private var documentSubscription: AnyCancellable?
    private var captureWindows: [NSWindow] = []
    private weak var captureKeyWindow: NSWindow?
    private var previousApplication: NSRunningApplication?

    init(hotKey: HotKey? = nil) {
        self.hotKey = hotKey ?? HotKey()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = preferences.appearance.native
        documentSubscription = session.objectWillChange.sink { [weak self] _ in
            // Published values are delivered before assignment; inspect the completed change.
            DispatchQueue.main.async {
                guard let self else { return }
                self.editorWindow?.isDocumentEdited = self.session.hasUnsavedChanges
                self.session.refreshClipboardStatus()
            }
        }
        buildMenus()
        languageSubscription = NotificationCenter.default.publisher(for: .rimvaLanguageChanged).sink { [weak self] _ in
            self?.buildMenus()
            self?.settingsWindow?.title = L("Rimva 设置")
            // SwiftUI recreates the editor content when its language changes.
            DispatchQueue.main.async { self?.alignEditorWindowControls() }
        }
        themeSubscription = NotificationCenter.default.publisher(for: .rimvaThemeChanged).sink { [weak self] _ in
            guard let self else { return }
            self.session.refreshClipboardStatus()
            self.editorWindow?.isDocumentEdited = self.session.hasUnsavedChanges
            for window in [self.editorWindow, self.settingsWindow].compactMap({ $0 }) {
                window.backgroundColor = self.preferences.palette.background
                window.contentView?.needsDisplay = true
            }
        }
        menuBarSubscription = preferences.$hidesMenuBarIcon.sink { [weak self] hidden in
            self?.statusItem?.isVisible = !hidden
        }
        capture.onCapture = { [weak self] image, opensEditor in self?.finishCapture(image, opensEditor: opensEditor) }
        capture.onCancel = { [weak self] in self?.restoreCaptureContext(restoresFocus: NSApp.isActive) }
        capture.onError = { [weak self] error in
            guard let self else { return }
            self.restoreCaptureContext(); self.preferences.refreshSystemStatus(); self.showError(error, captureFailure: true)
        }
        hotKey.onTrigger = { [weak self] action in
            guard let self else { return }
            // The same global key must also release an unfinished or hidden capture.
            if self.capture.isCapturing { self.capture.cancel(); return }
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
        // Login items receive an open-application event with the login launch marker.
        // Manual launches remain a way back into settings when the menu icon is hidden.
        if !Self.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent) { showEditor() }
    }

    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func finishCapture(_ image: CGImage, opensEditor: Bool = false) {
        session.load(image)
        preferences.refreshSystemStatus()
        var outputError: Error?
        if preferences.automaticCopy {
            do {
                try ImageExporter.copy(renderedImage(image))
                session.markCopied()
                session.notify(L("已自动复制当前成图；编辑后请重新复制。"))
            } catch { outputError = error }
        }
        if preferences.automaticSave {
            do {
                let url = try ImageExporter.saveAutomatically(renderedImage(image), in: preferences.saveFolder)
                session.markSaved(to: url)
                preferences.lastSavedURL = url
                session.notify(L("已自动保存 %@", url.lastPathComponent))
            } catch { outputError = error }
        }
        if opensEditor || preferences.opensEditorAfterCapture || outputError != nil ||
            (!preferences.automaticCopy && !preferences.automaticSave) {
            clearCaptureContext()
            showEditor()
            if let outputError { showError(outputError) }
        } else {
            // A completed quick capture must not prompt to save again on the next capture.
            session.releaseImage()
            // Activating the selection overlay can bring previously ordered-out windows back.
            editorWindow?.orderOut(nil)
            settingsWindow?.orderOut(nil)
            if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication.activate(options: [])
            } else {
                NSApp.hide(nil)
            }
            clearCaptureContext()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showEditor(); return true }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool { importImage(URL(fileURLWithPath: filename)); return true }

    func applicationDidResignActive(_ notification: Notification) {
        capture.cancelSelection()
    }

    func showEditor() {
        if editorWindow == nil {
            let window = makeWindow(size: CGSize(width: 1008, height: 650), title: "Rimva", resizable: true, editorSession: session)
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
            let hosting = NSHostingView(rootView: SettingsView(preferences: preferences, hotKey: hotKey) { [weak self] editing in
                if editing { self?.session.beginInteraction() } else { self?.session.endInteraction() }
            })
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

    private func makeWindow(size: CGSize, title: String, resizable: Bool, editorSession: EditorSession? = nil) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let frame = CGRect(origin: .zero, size: size)
        let window: NSWindow
        if let editorSession {
            let editor = EditorWindow(contentRect: frame, styleMask: mask, backing: .buffered, defer: false)
            editor.session = editorSession
            window = editor
        } else {
            window = NSWindow(contentRect: frame, styleMask: mask, backing: .buffered, defer: false)
        }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender !== editorWindow || confirmDiscard()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscard() ? .terminateNow : .terminateCancel
    }

    private func confirmDiscard() -> Bool {
        editorWindow?.makeFirstResponder(nil)
        guard session.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = L("保存当前图片？")
        alert.informativeText = L("当前图片尚未保存。继续会丢弃图片和编辑记录。")
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("丢弃"))
        alert.addButton(withTitle: L("取消"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return persistImage(chooseLocation: false)
        case .alertSecondButtonReturn: return true
        default: return false
        }
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
        guard !capturePending, !capture.isCapturing, NSApp.modalWindow == nil else { return }
        captureLauncher.close()
        let previous = NSWorkspace.shared.frontmostApplication
        guard confirmDiscard() else { return }
        previousApplication = previous
        captureWindows = [editorWindow, settingsWindow].compactMap { $0 }.filter(\.isVisible)
        captureKeyWindow = NSApp.keyWindow
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

    private func restoreCaptureContext(restoresFocus: Bool = true) {
        captureWindows.forEach { $0.orderFront(nil) }
        if !restoresFocus { clearCaptureContext(); return }
        if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options: [])
        } else if let captureKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            captureKeyWindow.makeKeyAndOrderFront(nil)
        }
        clearCaptureContext()
    }

    private func clearCaptureContext() {
        captureWindows.removeAll(); captureKeyWindow = nil; previousApplication = nil
    }

    func showCaptureLauncher() {
        guard !capturePending, !capture.isCapturing, NSApp.modalWindow == nil else { return }
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
        do {
            let image = try ImageExporter.read(url)
            guard confirmDiscard() else { return }
            session.load(image); showEditor()
        }
        catch { showError(error) }
    }

    func pasteImage() {
        let board = NSPasteboard.general
        if let url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first { importImage(url); return }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff),
           let image = NSBitmapImageRep(data: data)?.cgImage {
            guard confirmDiscard() else { return }
            session.load(image); showEditor(); return
        }
        session.notify(L("剪贴板中没有图片。"))
    }

    func copyImage() {
        guard let image = session.image else { return }
        do {
            editorWindow?.makeFirstResponder(nil)
            try ImageExporter.copy(renderedImage(image))
            session.markCopied()
            session.notify(L("已复制成图，可继续编辑。"))
        } catch { showError(error) }
    }

    func saveImage() { _ = persistImage(chooseLocation: false) }
    func saveImageAs() { _ = persistImage(chooseLocation: true) }
    func revealSavedImage() {
        guard let url = session.savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func persistImage(chooseLocation: Bool) -> Bool {
        guard let image = session.image else { return false }
        do {
            editorWindow?.makeFirstResponder(nil)
            let url: URL
            if !chooseLocation, let saved = session.savedURL { url = saved }
            else {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.canCreateDirectories = true
                panel.directoryURL = session.savedURL?.deletingLastPathComponent() ?? preferences.saveFolder
                panel.nameFieldStringValue = session.savedURL?.lastPathComponent ?? ImageExporter.suggestedName()
                guard panel.runModal() == .OK, let chosen = panel.url else { return false }
                url = chosen
            }
            let rendered = try renderedImage(image)
            try ImageExporter.save(rendered, to: url)
            session.markSaved(to: url)
            preferences.lastSavedURL = url
            session.notify(L("已保存 %@", url.lastPathComponent))
            return true
        } catch { showError(error); return false }
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
        let saveAs = item("另存为…", action: #selector(saveAsAction), key: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(saveAs)
        file.addItem(item("在访达中显示", action: #selector(revealAction)))
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
        status.button?.image = Self.statusImage
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
        status.isVisible = !preferences.hidesMenuBarIcon
    }

    // Menu bar counterpart of AppIcon.icon: selection corners around a card.
    private static let statusImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let corners = NSBezierPath()
            for (x, y, dx, dy) in [(1.75, 1.75, 1.0, 1.0), (16.25, 1.75, -1.0, 1.0), (16.25, 16.25, -1.0, -1.0), (1.75, 16.25, 1.0, -1.0)] {
                corners.move(to: NSPoint(x: x, y: y + 3.25 * dy))
                corners.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: x + 3.25 * dx, y: y), radius: 1.75)
                corners.line(to: NSPoint(x: x + 3.25 * dx, y: y))
            }
            corners.lineWidth = 1.5
            corners.lineCapStyle = .round
            corners.stroke()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 5.75, width: 8, height: 6.5), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Rimva"
        return image
    }()

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
    @objc private func saveAsAction() { saveImageAs() }
    @objc private func revealAction() { revealSavedImage() }
    @objc private func copyAction() { copyImage() }
    @objc private func closeAction() { NSApp.keyWindow?.performClose(nil) }
    @objc private func quitAction() { captureLauncher.close(); capture.cancel(); NSApp.terminate(nil) }
    @objc func paste(_ sender: Any?) { pasteImage() }
    @objc func undo(_ sender: Any?) { session.undo() }
    @objc func redo(_ sender: Any?) { session.redo() }
}
