import AppKit
import RimvaCore

/// Selection geometry uses AppKit points; only the final crop converts to native image pixels.
@MainActor
final class CaptureSelectionView: NSView {
    var onActivate: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var isWindowMode = false { didSet { needsDisplay = true; invalidateCursorRects() } }
    var isScrollingMode = false { didSet { refreshLabels() } }
    var selectedRect: NSRect? { selection }

    private let image: CGImage
    private let preview: NSImage
    private let windowRects: [NSRect]
    private var selection: NSRect?
    private var drag: Drag?
    private var startPoint = NSPoint.zero
    private var startRect = NSRect.zero
    private var tracking: NSTrackingArea?
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let confirmButton = NSButton(title: "", target: nil, action: nil)

    private enum Drag {
        case create, move, resize(Int)
    }

    init(image: CGImage, size: NSSize, windowRects: [NSRect]) {
        self.image = image
        preview = NSImage(cgImage: image, size: size)
        self.windowRects = windowRects
        super.init(frame: NSRect(origin: .zero, size: size))
        appearance = NSAppearance(named: .darkAqua)
        for button in [cancelButton, confirmButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.target = self
            addSubview(button)
        }
        cancelButton.action = #selector(cancelSelection)
        confirmButton.action = #selector(confirmSelection)
        confirmButton.contentTintColor = Preferences.shared.palette.onAccent
        confirmButton.bezelColor = Preferences.shared.palette.accent
        confirmButton.isEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLabels), name: .rimvaLanguageChanged, object: nil)
        refreshLabels()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refreshLabels() {
        cancelButton.title = L("取消 Esc")
        confirmButton.title = isScrollingMode ? L("开始 ↩") : L("截图 ↩")
        setAccessibilityLabel(isScrollingMode ? L("长截屏选区。拖动选择后按回车开始，Escape 取消。") : L("截图选区。拖动选择，空格切换窗口，回车截图，Escape 取消。"))
        needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        cancelButton.frame = NSRect(x: bounds.midX - 108, y: 30, width: 100, height: 34)
        confirmButton.frame = NSRect(x: bounds.midX + 8, y: 30, width: 100, height: 34)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isWindowMode ? .pointingHand : .crosshair)
        guard !isWindowMode, let selection else { return }
        addCursorRect(selection, cursor: .openHand)
        for (index, point) in handles(for: selection).enumerated() {
            let cursor: NSCursor = [1, 5].contains(index) ? .resizeUpDown : ([3, 7].contains(index) ? .resizeLeftRight : .crosshair)
            addCursorRect(NSRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14), cursor: cursor)
        }
    }

    func clearSelection() {
        selection = nil
        drag = nil
        refresh()
    }

    func updateWindowSelection(at point: NSPoint) {
        guard isWindowMode else { return }
        selection = windowRects.first(where: { $0.contains(point) })?.intersection(bounds)
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        if isWindowMode { onActivate?(); updateWindowSelection(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseMoved(with event: NSEvent) {
        if isWindowMode { onActivate?(); updateWindowSelection(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))
        if isWindowMode {
            updateWindowSelection(at: point)
            if selection != nil { onConfirm?() }
            return
        }
        startPoint = point
        if let selection {
            startRect = selection
            if let handle = handles(for: selection).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 9 }) {
                drag = .resize(handle)
                return
            }
            if selection.contains(point) {
                if event.clickCount == 2 { onConfirm?(); return }
                drag = .move
                NSCursor.closedHand.set()
                return
            }
        }
        selection = NSRect(origin: point, size: .zero)
        startRect = .zero
        drag = .create
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch drag {
        case .create:
            selection = rect(between: startPoint, and: point)
        case .move:
            let x = min(max(0, startRect.minX + point.x - startPoint.x), bounds.width - startRect.width)
            let y = min(max(0, startRect.minY + point.y - startPoint.y), bounds.height - startRect.height)
            selection = NSRect(origin: NSPoint(x: x, y: y), size: startRect.size)
        case .resize(let handle):
            var low = startRect.origin
            var high = NSPoint(x: startRect.maxX, y: startRect.maxY)
            // Eight handles run clockwise from bottom-left. The opposite edge stays fixed.
            if [0, 6, 7].contains(handle) { low.x = point.x }
            if [2, 3, 4].contains(handle) { high.x = point.x }
            if [0, 1, 2].contains(handle) { low.y = point.y }
            if [4, 5, 6].contains(handle) { high.y = point.y }
            selection = rect(between: low, and: high)
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        refresh()
    }

    override func draw(_ dirtyRect: NSRect) {
        preview.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        if let selection, selection.width > 0, selection.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            preview.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            Preferences.shared.palette.accent.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 2
            outline.stroke()
            if !isWindowMode {
                for point in handles(for: selection) {
                    let handle = NSBezierPath(roundedRect: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
                    NSColor.white.setFill()
                    handle.fill()
                    Preferences.shared.palette.accent.setStroke()
                    handle.lineWidth = 1
                    handle.stroke()
                }
            }
            if let pixelRect {
                let text = "\(Int(pixelRect.width)) × \(Int(pixelRect.height)) px"
                let y = selection.maxY + 10 > bounds.height - 80 ? max(80, selection.minY - 36) : selection.maxY + 10
                drawBadge(text, centerX: selection.midX, y: y, fontSize: 13)
            }
        }
        let hint = isScrollingMode ? L("拖动选择滚动区域  ·  回车：开始") : isWindowMode ? L("点选窗口  ·  空格：区域选择") : L("拖动选择区域  ·  空格：窗口选择  ·  回车：截图")
        drawBadge(hint, centerX: bounds.midX, y: bounds.height - 64, fontSize: 14)
    }

    func selectedImage() -> CGImage? {
        guard let pixelRect, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }

    private var pixelRect: CGRect? {
        guard let selection, !selection.isEmpty else { return nil }
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        // CGImage crops from the top-left; AppKit selection coordinates start at the bottom-left.
        let left = (selection.minX * scaleX).rounded()
        let right = (selection.maxX * scaleX).rounded()
        let top = ((bounds.height - selection.maxY) * scaleY).rounded()
        let bottom = ((bounds.height - selection.minY) * scaleY).rounded()
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    private func refresh() {
        confirmButton.isEnabled = pixelRect.map { $0.width >= 1 && $0.height >= 1 } ?? false
        needsDisplay = true
        invalidateCursorRects()
    }

    private func invalidateCursorRects() { window?.invalidateCursorRects(for: self) }
    private func clamped(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }
    private func rect(between a: NSPoint, and b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func handles(for r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }
    private func drawBadge(_ text: String, centerX: CGFloat, y: CGFloat, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = size.width + 24
        let box = NSRect(x: min(max(12, centerX - width / 2), bounds.width - width - 12), y: y, width: width, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 8), withAttributes: attributes)
    }

    @objc private func cancelSelection() { onCancel?() }
    @objc private func confirmSelection() { onConfirm?() }
}
