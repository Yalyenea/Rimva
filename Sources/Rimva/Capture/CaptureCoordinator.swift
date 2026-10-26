import AppKit
import ScreenCaptureKit
import RimvaCore

@MainActor
enum CaptureMode {
    case region, window, fullScreen, scrolling
}

@MainActor
final class CaptureCoordinator {
    var onCapture: ((CGImage, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var isCapturing = false

    private var captureTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var panels: [CapturePanel] = []
    private var views: [CaptureSelectionView] = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let windowKeys = CaptureKeySession(signature: 0x52494D57)
    private var mode: CaptureMode = .region
    private weak var activeView: CaptureSelectionView?
    private var scrollingSession: ScrollingCaptureSession?
    private var includesCursor = false

    static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }
    static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func start(_ mode: CaptureMode, includesCursor: Bool) {
        guard !isCapturing else { return }
        guard Self.permissionGranted || Self.requestPermission() else {
            onError?(CaptureFailure.permission)
            return
        }
        isCapturing = true
        self.mode = mode
        self.includesCursor = includesCursor
        let id = UUID()
        sessionID = id
        let pointer = NSEvent.mouseLocation
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                guard !content.displays.isEmpty else { throw CaptureFailure.noDisplay }
                let screens = NSScreen.screens
                let targetScreens = mode == .fullScreen
                    ? screens.filter { $0.frame.contains(pointer) }
                    : screens
                guard !targetScreens.isEmpty else { throw CaptureFailure.noDisplay }
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                if mode == .window {
                    // Only enumerate metadata. The window picker observes the live desktop.
                    try self.showSelection(targetScreens.map { ($0, nil) }, windows: content.windows)
                    return
                }
                var snapshots: [(NSScreen, CGImage?)] = []
                // Freeze every display before showing any overlay, so the overlay cannot enter another capture.
                for screen in targetScreens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                        throw CaptureFailure.noDisplay
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
                    configuration.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
                    configuration.showsCursor = includesCursor
                    configuration.captureResolution = .best
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    try Task.checkCancellation()
                    guard self.sessionID == id else { return }
                    snapshots.append((screen, image))
                }
                try self.showSelection(snapshots, windows: content.windows)
            } catch is CancellationError {
                // cancel() already releases the session and calls its completion.
            } catch {
                guard self.sessionID == id else { return }
                self.cleanUp()
                self.onError?(CaptureFailure.capture(error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard isCapturing else { return }
        cleanUp()
        onCancel?()
    }

    func cancelSelection() {
        // Context changes dismiss selection; live scrolling owns a separate session.
        guard !panels.isEmpty else { return }
        cancel()
    }

    static func isSelectableWindow(layer: Int, frame: CGRect, ownerPID: pid_t?) -> Bool {
        layer >= 0 && layer < Int(CGWindowLevelForKey(.screenSaverWindow))
            && frame.width.isFinite && frame.height.isFinite && frame.width >= 24 && frame.height >= 24
            && ownerPID != ProcessInfo.processInfo.processIdentifier
    }

    private func showSelection(_ snapshots: [(NSScreen, CGImage?)], windows: [SCWindow]) throws {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        // The Core Graphics list supplies front-to-back order; ScreenCaptureKit does not promise an order.
        let orderedIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let rank = Dictionary(orderedIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let selectable = windows.filter {
            $0.isOnScreen && Self.isSelectableWindow(layer: $0.windowLayer, frame: $0.frame,
                                                    ownerPID: $0.owningApplication?.processID)
        }.sorted { (rank[$0.windowID] ?? Int.max) < (rank[$1.windowID] ?? Int.max) }
        for (screen, image) in snapshots {
            let windowRects = selectable.map { window in
                let global = NSRect(x: window.frame.minX, y: primaryTop - window.frame.maxY,
                                    width: window.frame.width, height: window.frame.height)
                return global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            }
            let view = CaptureSelectionView(image: image, size: screen.frame.size, windowRects: windowRects)
            // visibleFrame excludes the menu bar and Dock; safeAreaInsets also covers the notch
            // when the menu bar is hidden. Convert global screen coordinates to this overlay.
            let insets = screen.safeAreaInsets
            let safeFrame = NSRect(x: screen.frame.minX + insets.left, y: screen.frame.minY + insets.bottom,
                                   width: screen.frame.width - insets.left - insets.right,
                                   height: screen.frame.height - insets.top - insets.bottom)
            view.toolbarSafeBounds = screen.visibleFrame.intersection(safeFrame)
                .offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            view.isWindowMode = mode == .window
            view.isScrollingMode = mode == .scrolling
            view.isFullScreenMode = mode == .fullScreen
            view.onActivate = { [weak self, weak view] in
                guard let self, let view else { return }
                self.activeView = view
                self.views.filter { $0 !== view }.forEach { $0.clearSelection() }
            }
            view.onConfirm = { [weak self, weak view] opensEditor in
                guard let self, let view else { return }
                if self.mode == .window {
                    guard let index = view.selectedWindowIndex else { NSSound.beep(); return }
                    self.captureWindow(selectable[index], opensEditor: opensEditor)
                    return
                }
                if self.mode == .scrolling {
                    guard view.canConfirm, let region = view.selectedRect else { NSSound.beep(); return }
                    let center = CGPoint(x: screen.frame.minX + region.midX, y: primaryTop - screen.frame.minY - region.midY)
                    let target = selectable.first { $0.frame.contains(center) }?.owningApplication
                    self.beginScrolling(screen: screen, region: region, target: target.flatMap { NSRunningApplication(processIdentifier: $0.processID) })
                    return
                }
                guard let image = view.selectedImage() else { NSSound.beep(); return }
                self.finish(image, opensEditor: opensEditor)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            let panel = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.acceptsSelectionKeys = mode != .window
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = mode != .window
            panel.backgroundColor = mode == .window ? .clear : .black
            // Explicitly register transparent pixels for clicks; otherwise the live
            // window-shaped hole can pass the click through to the original app.
            panel.ignoresMouseEvents = false
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.contentView = view
            panels.append(panel)
            views.append(view)
            panel.setFrame(screen.frame, display: false)
        }
        if mode == .window {
            try windowKeys.start([53, 36, 76, 49]) { [weak self] key in
                guard let self else { return }
                switch key {
                case 53: self.cancel()
                case 49: self.switchMode()
                default:
                    if self.activeView?.canConfirm == true { self.activeView?.onConfirm?(false) }
                    else { NSSound.beep() }
                }
            }
        } else {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Text fields keep their editing keys; the capture panel owns Escape.
                if event.window?.firstResponder is NSTextView { return event }
                switch event.keyCode {
                case 36, 76:
                    if self.activeView?.canConfirm == true { self.activeView?.onConfirm?(false) }
                    else { NSSound.beep() }
                    return nil
                case 49:
                    guard self.mode != .scrolling, self.mode != .fullScreen else { return nil }
                    self.switchMode()
                    return nil
                default: return event
                }
            }
        }
        let selectionID = sessionID
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionID == selectionID else { return }
                self.cancel()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sessionID == selectionID else { return }
                    self.cancelSelection()
                }
            })
        }
        panels.forEach { $0.orderFrontRegardless() }
        if let view = views.first(where: { $0.window?.frame.contains(NSEvent.mouseLocation) == true }), let panel = view.window {
            activeView = view
            if mode != .window {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
            view.updateWindowSelection(at: view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        }
    }

    private func switchMode() {
        let next: CaptureMode = mode == .window ? .region : .window
        let cursor = includesCursor
        cleanUp()
        start(next, includesCursor: cursor)
    }

    private func captureWindow(_ window: SCWindow, opensEditor: Bool) {
        guard let id = sessionID else { return }
        closeSelection()
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await NativeWindowCapture.image(of: window.windowID, includesCursor: self.includesCursor)
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.finish(image, opensEditor: opensEditor)
            } catch is CancellationError {
                // Cancellation already released the capture session.
            } catch {
                guard self.sessionID == id else { return }
                self.cleanUp()
                self.onError?(CaptureFailure.capture(error.localizedDescription))
            }
        }
    }

    private func finish(_ image: CGImage, opensEditor: Bool = false) {
        cleanUp()
        onCapture?(image, opensEditor)
    }

    private func beginScrolling(screen: NSScreen, region: NSRect, target: NSRunningApplication?) {
        guard region.width >= 40, region.height >= 80 else {
            NSSound.beep()
            return
        }
        closeSelection()
        // Return keyboard input to the chosen content before live scrolling begins.
        target?.activate(options: [])
        let session = ScrollingCaptureSession(screen: screen, region: region, includesCursor: includesCursor)
        session.onComplete = { [weak self] image, opensEditor in self?.finish(image, opensEditor: opensEditor) }
        session.onCancel = { [weak self] in self?.cancel() }
        session.onReselect = { [weak self] in
            guard let self else { return }
            let cursor = self.includesCursor
            self.cleanUp()
            self.start(.scrolling, includesCursor: cursor)
        }
        session.onError = { [weak self] error in
            guard let self else { return }
            self.cleanUp()
            self.onError?(error)
        }
        scrollingSession = session
        session.start()
    }

    private func cleanUp() {
        sessionID = nil
        captureTask?.cancel()
        captureTask = nil
        scrollingSession?.stop()
        scrollingSession = nil
        closeSelection()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
        workspaceObservers.removeAll()
        isCapturing = false
    }

    private func closeSelection() {
        windowKeys.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panels.forEach { $0.orderOut(nil); $0.contentView = nil; $0.close() }
        panels.removeAll()
        views.removeAll()
        activeView = nil
        NSCursor.arrow.set()
    }
}

private enum CaptureFailure: LocalizedError {
    case permission, noDisplay, capture(String)
    var errorDescription: String? {
        switch self {
        case .permission: return L("需要屏幕录制权限。请在系统设置中允许 Rimva 录制屏幕，再重新截图。")
        case .noDisplay: return L("无法找到可截图的显示器。请检查显示器连接后重试。")
        case .capture(let reason): return L("截图失败：%@", reason)
        }
    }
}

@MainActor
final class CapturePanel: NSPanel {
    var onCancel: (() -> Void)?
    var acceptsSelectionKeys = true
    override var canBecomeKey: Bool { acceptsSelectionKeys }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Handle Escape before the focused control, including the dimensions field editor.
        if event.type == .keyDown, event.keyCode == 53 {
            cancelOperation(nil)
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
