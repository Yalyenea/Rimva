import AppKit
import Combine
import RimvaCore
import ScreenCaptureKit
import SwiftUI

/// A live region stays interactive while stable snapshots are stitched off the main thread.
@MainActor
final class ScrollingCaptureSession {
    var onComplete: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?

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
        case .appended, .unchanged:
            progress.phase = .ready
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
    }

    private func finish() {
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
                self.onComplete?(image)
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
        let size = NSSize(width: min(440, visible.width - 24), height: 82)
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
            finish: { [weak self] in self?.finish() }, cancel: { [weak self] in self?.onCancel?() }).ignoresSafeArea())
        toolbar = panel
        panel.orderFrontRegardless()
    }
}

private actor ScrollCaptureBuffer {
    private var stitcher: ScrollingStitcher?
    func begin(_ image: CGImage) throws { stitcher = try ScrollingStitcher(first: image) }
    func append(_ candidate: CGImage, ifStableWith settled: CGImage) throws -> ScrollingAppendResult? {
        guard ScrollingStitcher.framesMatch(candidate, settled) else { return nil }
        guard var current = stitcher else { throw ScrollingStitchingError.invalidDimensions }
        let result = try current.append(settled)
        stitcher = current
        return result
    }
    func dimensions() -> (Int, Int) { (stitcher?.width ?? 0, stitcher?.height ?? 0) }
    func image() throws -> CGImage {
        guard let stitcher else { throw ScrollingStitchingError.invalidDimensions }
        return try stitcher.image()
    }
}

@MainActor
private final class ScrollCaptureProgress: ObservableObject {
    enum Phase { case ready, moving, overlap, limit }
    @Published var phase = Phase.ready
    @Published var width = 0
    @Published var height = 0
    @Published var busy = false
    @Published var atLimit = false
}

private struct ScrollCaptureToolbar: View {
    @ObservedObject var progress: ScrollCaptureProgress
    var finish: () -> Void
    var cancel: () -> Void
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label(L("长截屏"), systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(progress.width) × \(progress.height) px")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(nsColor: preferences.palette.secondary))
            }
            HStack(spacing: 8) {
                Text(status).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color(nsColor: progress.phase == .overlap ? preferences.palette.warning : preferences.palette.secondary))
                Button(L("取消"), action: cancel).buttonStyle(ThemedActionStyle())
                Button(progress.phase == .overlap ? L("保留已拼部分") : L("完成"), action: finish)
                    .buttonStyle(ThemedActionStyle(prominent: true)).disabled(progress.busy)
            }
        }
        .padding(12)
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .background(Color(nsColor: preferences.palette.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: preferences.palette.separator), lineWidth: 0.5))
        .environment(\.locale, L10n.locale)
    }

    private var status: String {
        if progress.busy { return L("正在生成…") }
        switch progress.phase {
        case .ready: return L("向下滚动，停稳后自动拼接")
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
    case displayUnavailable
    var errorDescription: String? { L("显示器已断开，请重新开始长截屏。") }
}
