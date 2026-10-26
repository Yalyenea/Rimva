import AppKit
import Combine
import Carbon
import RimvaCore
import ScreenCaptureKit
import SwiftUI

/// A live region stays interactive while stable snapshots are stitched off the main thread.
@MainActor
final class ScrollingCaptureSession {
    var onComplete: ((CGImage, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onReselect: (() -> Void)?

    private let screen: NSScreen
    private let region: NSRect
    private let includesCursor: Bool
    private let progress = ScrollCaptureProgress()
    private let buffer = ScrollCaptureBuffer()
    private var captureTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var border: NSPanel?
    private var toolbar: NSPanel?
    private var running = false
    private var escapeKey: EventHotKeyRef?
    private var escapeHandler: EventHandlerRef?

    init(screen: NSScreen, region: NSRect, includesCursor: Bool) {
        self.screen = screen
        self.region = region
        self.includesCursor = includesCursor
    }

    func start() {
        guard !running else { return }
        running = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.installEscapeKey()
                // Remove the frozen selection panels before taking the first live frame.
                try await Task.sleep(for: .milliseconds(160))
                // Include hidden editor windows so Rimva remains discoverable before its floating controls exist.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Task.checkCancellation()
                guard self.running,
                      let number = self.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                    throw ScrollCaptureFailure.displayUnavailable
                }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                // Excluding the application also excludes panels created after the filter, including this toolbar.
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: self.region.minX, y: self.screen.frame.height - self.region.maxY,
                                           width: self.region.width, height: self.region.height)
                config.width = max(1, Int((self.region.width * CGFloat(filter.pointPixelScale)).rounded()))
                config.height = max(1, Int((self.region.height * CGFloat(filter.pointPixelScale)).rounded()))
                config.showsCursor = self.includesCursor
                config.captureResolution = .best
                self.filter = filter
                self.configuration = config
                let first = try await self.snapshot()
                try Task.checkCancellation()
                try await self.buffer.begin(first)
                guard self.running else { return }
                await self.updateDimensions()
                self.showControls()
                try await self.poll()
            } catch is CancellationError {
                // stop() or finish() owns the corresponding UI transition.
            } catch {
                guard self.running else { return }
                self.stop()
                self.onError?(error)
            }
        }
    }

    func stop() {
        running = false
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        if let escapeHandler { RemoveEventHandler(escapeHandler) }
        escapeKey = nil; escapeHandler = nil
        captureTask?.cancel()
        finishTask?.cancel()
        captureTask = nil
        finishTask = nil
        for panel in [border, toolbar].compactMap({ $0 }) {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        border = nil
        toolbar = nil
        filter = nil
        configuration = nil
    }

    private func snapshot() async throws -> CGImage {
        guard let filter, let configuration else { throw CancellationError() }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func poll() async throws {
        while running, !progress.atLimit {
            try await Task.sleep(for: .milliseconds(320))
            let candidate = try await snapshot()
            try await Task.sleep(for: .milliseconds(150))
            let settled = try await snapshot()
            try Task.checkCancellation()
            let result = try await buffer.append(candidate, ifStableWith: settled)
            try Task.checkCancellation()
            guard running else { return }
            apply(result)
            await updateDimensions()
        }
    }

    private func apply(_ result: ScrollingAppendResult?) {
        switch result {
        case .appended(let pixels):
            progress.phase = .appended
            progress.lastAdded = pixels
        case .unchanged:
            progress.phase = .unchanged
        case .noOverlap:
            progress.phase = .overlap
        case .limitReached:
            progress.phase = .limit
            progress.atLimit = true
        case nil:
            // An animation or ongoing smooth scroll must settle before it can become a seam.
            progress.phase = .moving
        }
    }

    private func updateDimensions() async {
        let size = await buffer.dimensions()
        progress.width = size.0
        progress.height = size.1
        let preview = await buffer.preview()
        progress.frames = preview.0
        progress.preview = preview.1
        progress.seam = preview.2
    }

    private func installEscapeKey() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let signature: OSType = 0x52534345
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x52534345 else { return OSStatus(eventNotHandledErr) }
            let session = Unmanaged<ScrollingCaptureSession>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { session.onCancel?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &escapeHandler)
        guard result == noErr else { throw ScrollCaptureFailure.escapeUnavailable }
        // A temporary hotkey keeps Escape available while the user scrolls in another app,
        // without requiring Accessibility permission for a global keyboard monitor.
        guard RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: signature, id: 1),
                                  GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &escapeKey) == noErr else {
            throw ScrollCaptureFailure.escapeUnavailable
        }
    }

    private func finish(opensEditor: Bool = false) {
        guard running, !progress.busy else { return }
        let keepAcceptedOnly = progress.phase == .overlap || progress.atLimit
        progress.busy = true
        let polling = captureTask
        polling?.cancel()
        finishTask = Task { [weak self] in
            guard let self else { return }
            await polling?.value
            guard self.running else { return }
            do {
                if !keepAcceptedOnly {
                    let candidate = try await self.snapshot()
                    try await Task.sleep(for: .milliseconds(180))
                    let settled = try await self.snapshot()
                    try Task.checkCancellation()
                    let result = try await self.buffer.append(candidate, ifStableWith: settled)
                    self.apply(result)
                    await self.updateDimensions()
                    guard self.running else { return }
                    // Give the user an explicit choice to retain the accepted portion after a missed overlap.
                    if result == nil || result == .noOverlap {
                        self.progress.busy = false
                        self.resumePolling()
                        return
                    }
                }
                let image = try await self.buffer.image()
                try Task.checkCancellation()
                guard self.running else { return }
                self.stop()
                self.onComplete?(image, opensEditor)
            } catch is CancellationError {
            } catch {
                guard self.running else { return }
                self.stop()
                self.onError?(error)
            }
        }
    }

    private func resumePolling() {
        captureTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.poll() }
            catch is CancellationError {}
            catch {
                guard self.running else { return }
                self.stop()
                self.onError?(error)
            }
        }
    }

    private func showControls() {
        let globalRegion = region.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let border = NSPanel(contentRect: globalRegion.insetBy(dx: -2, dy: -2), styleMask: .borderless,
                             backing: .buffered, defer: false)
        border.isReleasedWhenClosed = false
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.hidesOnDeactivate = false
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = ScrollCaptureBorder()
        self.border = border
        border.orderFrontRegardless()

        let visible = screen.visibleFrame
        let size = NSSize(width: min(660, visible.width - 24), height: 112)
        var origin = NSPoint(x: globalRegion.midX - size.width / 2, y: globalRegion.maxY + 10)
        if origin.y + size.height > visible.maxY { origin.y = globalRegion.minY - size.height - 10 }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        let panel = ScrollCapturePanel(contentRect: NSRect(origin: origin, size: size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = L("长截屏")
        panel.onEscape = { [weak self] in self?.onCancel?() }
        panel.contentView = NSHostingView(rootView: ScrollCaptureToolbar(progress: progress,
            finish: { [weak self] in self?.finish() }, edit: { [weak self] in self?.finish(opensEditor: true) }, cancel: { [weak self] in self?.onCancel?() },
            reselect: { [weak self] in self?.onReselect?() }).ignoresSafeArea())
        toolbar = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

private actor ScrollCaptureBuffer {
    private var stitcher: ScrollingStitcher?
    private var lastFrame: CGImage?
    private var seam: CGFloat?
    func begin(_ image: CGImage) throws { stitcher = try ScrollingStitcher(first: image); lastFrame = image; seam = nil }
    func append(_ candidate: CGImage, ifStableWith settled: CGImage) throws -> ScrollingAppendResult? {
        guard ScrollingStitcher.framesMatch(candidate, settled) else { return nil }
        guard var current = stitcher else { throw ScrollingStitchingError.invalidDimensions }
        let result = try current.append(settled)
        stitcher = current
        if case .appended = result {
            lastFrame = settled
            seam = current.lastAppendStart.map { CGFloat($0) / CGFloat(settled.height) }
        }
        return result
    }
    func dimensions() -> (Int, Int) { (stitcher?.width ?? 0, stitcher?.height ?? 0) }
    func preview() -> (Int, CGImage?, CGFloat?) { (stitcher?.frameCount ?? 0, lastFrame, seam) }
    func image() throws -> CGImage {
        guard let stitcher else { throw ScrollingStitchingError.invalidDimensions }
        return try stitcher.image()
    }
}

@MainActor
private final class ScrollCaptureProgress: ObservableObject {
    enum Phase { case ready, appended, unchanged, moving, overlap, limit }
    @Published var phase = Phase.ready
    @Published var width = 0
    @Published var height = 0
    @Published var busy = false
    @Published var atLimit = false
    @Published var frames = 1
    @Published var lastAdded = 0
    @Published var preview: CGImage?
    @Published var seam: CGFloat?
}

private struct ScrollCaptureToolbar: View {
    @ObservedObject var progress: ScrollCaptureProgress
    var finish: () -> Void
    var edit: () -> Void
    var cancel: () -> Void
    var reselect: () -> Void
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        HStack(spacing: 10) {
            if let preview = progress.preview {
                Image(decorative: preview, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        if let seam = progress.seam {
                            GeometryReader { geometry in
                                Rectangle().fill(Color(nsColor: preferences.palette.accent)).frame(height: 1)
                                    .offset(y: geometry.size.height * seam)
                            }
                        }
                    }
                    .frame(maxWidth: 90, maxHeight: 84)
                    .help(L("最近一段；横线为拼接位置"))
            }
            VStack(spacing: 8) {
            HStack {
                Text(L("已拼接 %d 段", progress.frames)).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(progress.width) × \(progress.height) px")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(nsColor: preferences.palette.secondary))
            }
            if progress.lastAdded > 0 {
                Text(L("最近新增 %d px", progress.lastAdded)).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(status).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color(nsColor: progress.phase == .overlap ? preferences.palette.warning : preferences.palette.secondary))
                Button(L("重新框选"), action: reselect).buttonStyle(ThemedActionStyle()).disabled(progress.busy)
                Button(L("取消"), action: cancel).buttonStyle(ThemedActionStyle()).help("Esc")
                Button(L("在编辑器中打开"), action: edit).buttonStyle(ThemedActionStyle()).disabled(progress.busy)
                Button(progress.phase == .overlap ? L("保留已拼部分") : L("完成"), action: finish)
                    .buttonStyle(ThemedActionStyle(prominent: true)).disabled(progress.busy)
            }
            }
        }
        .padding(12)
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .background(Color(nsColor: preferences.palette.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: preferences.palette.separator), lineWidth: 0.5))
        .environment(\.locale, L10n.locale)
        .background(InitialFocusReset())
        .focusEffectDisabled()
    }

    private var status: String {
        if progress.busy { return L("正在生成…") }
        switch progress.phase {
        case .ready: return L("向下滚动，停稳后自动拼接")
        case .appended: return L("已拼接，可继续向下滚动")
        case .unchanged: return L("画面未变化")
        case .moving: return L("等待画面停稳")
        case .overlap: return L("回滚少许，或避开固定侧栏重新框选")
        case .limit: return L("已达到长度上限")
        }
    }
}

@MainActor
private final class ScrollCapturePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
private final class ScrollCaptureBorder: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Preferences.shared.palette.accent.withAlphaComponent(0.75).setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 1
        outline.stroke()
    }
}

private enum ScrollCaptureFailure: LocalizedError {
    case displayUnavailable, escapeUnavailable
    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return L("显示器已断开，请重新开始长截屏。")
        case .escapeUnavailable: return L("无法注册 Esc 取消键，请关闭占用 Esc 的应用后重试。")
        }
    }
}
