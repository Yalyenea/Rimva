import AppKit
import ScreenCaptureKit
import RimvaCore

@MainActor
enum CaptureMode {
    case region, window, fullScreen, scrolling
}

@MainActor
final class CaptureCoordinator {
    var onCapture: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var isCapturing = false

    private var captureTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var panels: [CapturePanel] = []
    private var views: [CaptureSelectionView] = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
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
                let screens = NSScreen.screens
                let targetScreens = mode == .fullScreen
                    ? screens.filter { $0.frame.contains(pointer) }
                    : screens
                guard !targetScreens.isEmpty else { throw CaptureFailure.noDisplay }
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                var snapshots: [(NSScreen, CGImage)] = []
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
                if mode == .fullScreen, let image = snapshots.first?.1 {
                    self.finish(image)
                    return
                }
                self.showSelection(snapshots, windows: content.windows)
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

    private func showSelection(_ snapshots: [(NSScreen, CGImage)], windows: [SCWindow]) {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        // The Core Graphics list supplies front-to-back order; ScreenCaptureKit does not promise an order.
        let orderedIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let rank = Dictionary(orderedIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let selectable = windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 24 && $0.frame.height >= 24
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.sorted { (rank[$0.windowID] ?? Int.max) < (rank[$1.windowID] ?? Int.max) }
        for (screen, image) in snapshots {
            let windowRects = selectable.map { window in
                let global = NSRect(x: window.frame.minX, y: primaryTop - window.frame.maxY,
                                    width: window.frame.width, height: window.frame.height)
                return global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            }
            let view = CaptureSelectionView(image: image, size: screen.frame.size, windowRects: windowRects)
            view.isWindowMode = mode == .window
            view.isScrollingMode = mode == .scrolling
            view.onActivate = { [weak self, weak view] in
                guard let self, let view else { return }
                self.activeView = view
                self.views.filter { $0 !== view }.forEach { $0.clearSelection() }
            }
            view.onConfirm = { [weak self, weak view] in
                guard let self, let view else { return }
                if self.mode == .scrolling {
                    guard let region = view.selectedRect else { NSSound.beep(); return }
                    self.beginScrolling(screen: screen, region: region)
                    return
                }
                guard let image = view.selectedImage() else { NSSound.beep(); return }
                self.finish(image)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            let panel = CapturePanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.contentView = view
            panels.append(panel)
            views.append(view)
            panel.setFrame(screen.frame, display: false)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.cancel(); return nil
            case 36, 76: self.activeView?.onConfirm?(); return nil
            case 49:
                guard self.mode != .scrolling else { return nil }
                self.mode = self.mode == .window ? .region : .window
                self.views.forEach { $0.isWindowMode = self.mode == .window; $0.clearSelection() }
                if let view = self.views.first(where: { $0.window?.frame.contains(NSEvent.mouseLocation) == true }) {
                    self.activeView = view
                    view.updateWindowSelection(at: view.convert(view.window!.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
                }
                return nil
            default: return event
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.forEach { $0.orderFrontRegardless() }
        if let view = views.first(where: { $0.window?.frame.contains(NSEvent.mouseLocation) == true }), let panel = view.window {
            activeView = view
            panel.makeKey()
            panel.makeFirstResponder(view)
            view.updateWindowSelection(at: view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        }
    }

    private func finish(_ image: CGImage) {
        cleanUp()
        onCapture?(image)
    }

    private func beginScrolling(screen: NSScreen, region: NSRect) {
        guard region.width >= 40, region.height >= 80 else {
            cleanUp()
            onError?(CaptureFailure.smallScrollRegion)
            return
        }
        closeSelection()
        let session = ScrollingCaptureSession(screen: screen, region: region, includesCursor: includesCursor)
        session.onComplete = { [weak self] in self?.finish($0) }
        session.onCancel = { [weak self] in self?.cancel() }
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
        isCapturing = false
    }

    private func closeSelection() {
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
    case permission, noDisplay, smallScrollRegion, capture(String)
    var errorDescription: String? {
        switch self {
        case .permission: return L("需要屏幕录制权限。请在系统设置中允许 Rimva 录制屏幕，再重新截图。")
        case .noDisplay: return L("无法找到可截图的显示器。请检查显示器连接后重试。")
        case .smallScrollRegion: return L("请扩大长截屏选区。")
        case .capture(let reason): return L("截图失败：%@", reason)
        }
    }
}

@MainActor
private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
