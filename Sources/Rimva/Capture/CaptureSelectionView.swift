import AppKit
import RimvaCore

/// Selection geometry uses AppKit points; only the final crop converts to native image pixels.
@MainActor
final class CaptureSelectionView: NSView {
    var onActivate: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var isWindowMode = false { didSet { needsDisplay = true; invalidateCursorRects() } }
    var isScrollingMode = false { didSet { refreshLabels(); refresh() } }
    var selectedRect: NSRect? { selection }
    var canConfirm: Bool {
        guard let selection, let pixelRect else { return false }
        return isScrollingMode ? selection.width >= 40 && selection.height >= 80 : pixelRect.width >= 1 && pixelRect.height >= 1
    }

    private let image: CGImage
    private let preview: NSImage
    private let windowRects: [NSRect]
    private var selection: NSRect?
    private var drag: Drag?
    private var startPoint = NSPoint.zero
    private var startRect = NSRect.zero
    private var tracking: NSTrackingArea?
    private let toolbar = CaptureToolbarSurface()
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let confirmButton = NSButton(title: "", target: nil, action: nil)
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let ratioPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var pointer: NSPoint?
    private var selectedRatio: CGFloat? { [nil, CGFloat(1), CGFloat(4) / 3, CGFloat(16) / 9][ratioPicker.indexOfSelectedItem] }

    private enum Drag {
        case create, move, resize(Int)
    }

    init(image: CGImage, size: NSSize, windowRects: [NSRect]) {
        self.image = image
        preview = NSImage(cgImage: image, size: size)
        self.windowRects = windowRects
        super.init(frame: NSRect(origin: .zero, size: size))
        appearance = Preferences.shared.appearance.native
        addSubview(toolbar)
        for button in [cancelButton, confirmButton] {
            button.cell = CaptureActionCell(textCell: "")
            button.setButtonType(.momentaryPushIn)
            button.isBordered = false
            button.focusRingType = .none
            button.font = .systemFont(ofSize: 12, weight: button === confirmButton ? .medium : .regular)
            button.target = self
            toolbar.addSubview(button)
        }
        cancelButton.action = #selector(cancelSelection)
        confirmButton.action = #selector(confirmSelection)
        confirmButton.isEnabled = false
        for field in [widthField, heightField] {
            field.cell = CaptureDimensionCell(textCell: "")
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.alignment = .center
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
            field.focusRingType = .none
            field.target = self; field.action = #selector(resizeFromFields(_:))
            field.formatter = {
                let formatter = NumberFormatter(); formatter.allowsFloats = false; formatter.minimum = 1
                return formatter
            }()
            toolbar.addSubview(field)
        }
        ratioPicker.cell = CaptureRatioCell(textCell: "", pullsDown: false)
        ratioPicker.isBordered = false
        ratioPicker.focusRingType = .none
        ratioPicker.target = self; ratioPicker.action = #selector(changeRatio)
        ratioPicker.font = .systemFont(ofSize: 12)
        toolbar.addSubview(ratioPicker)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLabels), name: .rimvaLanguageChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance), name: .rimvaThemeChanged, object: nil)
        refreshLabels()
        refreshAppearance()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refreshLabels() {
        cancelButton.title = L("取消")
        cancelButton.toolTip = L("取消 Esc")
        confirmButton.title = isScrollingMode ? L("开始") : L("截图")
        confirmButton.toolTip = isScrollingMode ? L("按回车开始") : L("按回车截图")
        let ratio = max(0, ratioPicker.indexOfSelectedItem)
        ratioPicker.removeAllItems(); ratioPicker.addItems(withTitles: [L("自由"), "1:1", "4:3", "16:9"])
        ratioPicker.selectItem(at: ratio)
        widthField.toolTip = L("宽度（像素）"); widthField.setAccessibilityLabel(L("宽度（像素）"))
        heightField.toolTip = L("高度（像素）"); heightField.setAccessibilityLabel(L("高度（像素）"))
        ratioPicker.setAccessibilityLabel(L("选区比例"))
        ratioPicker.toolTip = L("选区比例")
        setAccessibilityLabel(isScrollingMode ? L("长截屏选区。拖动选择后按回车开始，Escape 取消。") : L("截图选区。拖动选择，空格切换窗口，回车截图，Escape 取消。"))
        needsLayout = true; needsDisplay = true
        toolbar.needsDisplay = true
    }
    @objc private func refreshAppearance() {
        appearance = Preferences.shared.appearance.native
        for field in [widthField, heightField] { field.textColor = Preferences.shared.palette.text }
        for view in [toolbar, cancelButton, confirmButton, widthField, heightField, ratioPicker] { view.needsDisplay = true }
        needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        let showPrecision = selection != nil && !isWindowMode
        // Equal action widths follow the longest localized title, with no reserved shortcut slot.
        let actionWidth = ceil(max(cancelButton.attributedTitle.size().width, confirmButton.attributedTitle.size().width) + 16)
        let width: CGFloat = (showPrecision ? 238 : 16) + actionWidth * 2
        let x = max(8, min((selection?.midX ?? bounds.midX) - width / 2, bounds.width - width - 8))
        let below = (selection?.minY ?? 74) - 44
        let above = (selection?.maxY ?? 0) + 10
        let y = max(8, min(below >= 8 ? below : above, bounds.height - 42))
        toolbar.frame = NSRect(x: x, y: y, width: width, height: 34)
        toolbar.showsPrecision = showPrecision
        for field in [widthField, heightField] { field.isHidden = !showPrecision }
        ratioPicker.isHidden = !showPrecision
        widthField.frame = NSRect(x: 6, y: 5, width: 48, height: 24)
        heightField.frame = NSRect(x: 72, y: 5, width: 48, height: 24)
        ratioPicker.frame = NSRect(x: 156, y: 5, width: 56, height: 24)
        let buttonX: CGFloat = showPrecision ? 228 : 6
        cancelButton.frame = NSRect(x: buttonX, y: 5, width: actionWidth, height: 24)
        confirmButton.frame = NSRect(x: buttonX + actionWidth + 4, y: 5, width: actionWidth, height: 24)
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
        pointer = clamped(convert(event.locationInWindow, from: nil)); needsDisplay = true
        if isWindowMode { onActivate?(); updateWindowSelection(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseExited(with event: NSEvent) { pointer = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))
        pointer = point
        if isWindowMode {
            updateWindowSelection(at: point)
            if canConfirm { onConfirm?() }
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
                if event.clickCount == 2 { confirmSelection(); return }
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
        pointer = point
        switch drag {
        case .create:
            var end = point
            if let ratio = selectedRatio {
                let dx = point.x - startPoint.x, dy = point.y - startPoint.y
                var width = min(abs(dx), abs(dy) * ratio)
                width = min(width, dx < 0 ? startPoint.x : bounds.maxX - startPoint.x)
                width = min(width, (dy < 0 ? startPoint.y : bounds.maxY - startPoint.y) * ratio)
                end = NSPoint(x: startPoint.x + (dx < 0 ? -width : width), y: startPoint.y + (dy < 0 ? -width / ratio : width / ratio))
            }
            selection = rect(between: startPoint, and: end)
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
            // Region dimensions already live in the toolbar; only window mode and validation need a badge.
            if let pixelRect, isWindowMode || (isScrollingMode && !canConfirm) {
                let text = isScrollingMode && !canConfirm ? L("长截屏选区至少为 40 × 80 pt") : "\(Int(pixelRect.width)) × \(Int(pixelRect.height)) px"
                let y = selection.maxY + 10 > bounds.height - 80 ? max(80, selection.minY - 36) : selection.maxY + 10
                drawBadge(text, centerX: selection.midX, y: y, fontSize: 13)
            }
        }
        if let pointer, !isWindowMode, selection == nil || drag != nil { drawMagnifier(at: pointer) }
        let hint = isScrollingMode ? L("拖动选择滚动区域  ·  方向键微调  ·  回车：开始") : isWindowMode ? L("点选窗口  ·  空格：区域选择") : L("方向键移动  ·  ⇧ 10 px  ·  ⌥ 调整尺寸  ·  空格切换窗口")
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
        confirmButton.isEnabled = canConfirm
        needsLayout = true
        if let pixelRect {
            widthField.integerValue = Int(pixelRect.width); heightField.integerValue = Int(pixelRect.height)
        }
        needsDisplay = true
        invalidateCursorRects()
    }

    override func keyDown(with event: NSEvent) {
        guard [123, 124, 125, 126].contains(event.keyCode), !isWindowMode, var selection else { super.keyDown(with: event); return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
        let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
        let scaleX = bounds.width / CGFloat(image.width), scaleY = bounds.height / CGFloat(image.height)
        if event.modifierFlags.contains(.option) {
            selection.size.width = min(bounds.maxX - selection.minX, max(scaleX, selection.width + dx * scaleX))
            selection.size.height = min(bounds.maxY - selection.minY, max(scaleY, selection.height + dy * scaleY))
        } else {
            selection.origin.x = min(bounds.maxX - selection.width, max(0, selection.minX + dx * scaleX))
            selection.origin.y = min(bounds.maxY - selection.height, max(0, selection.minY + dy * scaleY))
        }
        self.selection = selection; refresh()
    }

    @objc private func resizeFromFields(_ sender: Any?) {
        guard var selection else { return }
        var width = max(1, CGFloat(widthField.integerValue)) * bounds.width / CGFloat(image.width)
        var height = max(1, CGFloat(heightField.integerValue)) * bounds.height / CGFloat(image.height)
        if let ratio = selectedRatio {
            if sender as? NSTextField === heightField { width = height * ratio }
            else { height = width / ratio }
        }
        let factor = min(1, min(bounds.width / width, bounds.height / height))
        width *= factor; height *= factor
        selection.size = NSSize(width: width, height: height)
        selection.origin.x = min(selection.minX, bounds.maxX - width)
        selection.origin.y = min(selection.minY, bounds.maxY - height)
        self.selection = selection
        window?.makeFirstResponder(self); refresh()
    }

    @objc private func changeRatio() { if selectedRatio != nil { resizeFromFields(widthField) } }

    private func drawMagnifier(at point: NSPoint) {
        let scaleX = CGFloat(image.width) / bounds.width, scaleY = CGFloat(image.height) / bounds.height
        let x = min(image.width - 1, Int((point.x * scaleX).rounded()))
        let y = min(image.height - 1, Int(((bounds.height - point.y) * scaleY).rounded()))
        let source = CGRect(x: x - 8, y: y - 8, width: 17, height: 17)
        let sample = source.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: sample) else { return }
        let box = NSRect(x: max(8, min(point.x + 24, bounds.width - 112)), y: max(8, min(point.y + 24, bounds.height - 112)), width: 102, height: 102)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.black.setFill(); box.fill()
        let destination = NSRect(x: box.minX + (sample.minX - source.minX) * 6,
                                 y: box.maxY - (sample.maxY - source.minY) * 6,
                                 width: sample.width * 6, height: sample.height * 6)
        NSImage(cgImage: crop, size: .zero).draw(in: destination)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: box); path.lineWidth = 2; path.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: box.midX, y: box.minY)); cross.line(to: NSPoint(x: box.midX, y: box.maxY))
        cross.move(to: NSPoint(x: box.minX, y: box.midY)); cross.line(to: NSPoint(x: box.maxX, y: box.midY))
        cross.lineWidth = 0.5; cross.stroke()
        NSGraphicsContext.restoreGraphicsState()
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
    @objc private func confirmSelection() { if canConfirm { onConfirm?() } else { NSSound.beep() } }
}

@MainActor
private enum CaptureToolbarDrawing {
    static func cell(_ rect: NSRect, pressed: Bool = false, focused: Bool = false) {
        let palette = Preferences.shared.palette
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (pressed ? palette.selection : palette.elevated).setFill(); shape.fill()
        (focused ? palette.accent : palette.separator).setStroke()
        shape.lineWidth = focused ? 1 : 0.5; shape.stroke()
    }

    static func label(_ title: String, in rect: NSRect, font: NSFont = .systemFont(ofSize: 12),
                      color: NSColor? = nil) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color ?? Preferences.shared.palette.text, .paragraphStyle: paragraph
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                                withAttributes: attributes)
    }
}

@MainActor
private final class CaptureToolbarSurface: NSView {
    var showsPrecision = false { didSet { if oldValue != showsPrecision { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Preferences.shared.palette
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        // Use exactly the launcher's theme colors; screenshots and mockups can carry different color profiles.
        palette.background.setFill(); shape.fill()
        palette.separator.setStroke(); shape.lineWidth = 0.5; shape.stroke()
        guard showsPrecision else { return }
        CaptureToolbarDrawing.label("×", in: NSRect(x: 58, y: 5, width: 10, height: 24), color: palette.secondary)
        CaptureToolbarDrawing.label("px", in: NSRect(x: 126, y: 5, width: 14, height: 24),
                                    font: .systemFont(ofSize: 10), color: palette.secondary)
        palette.separator.setStroke()
        for x: CGFloat in [148, 220] {
            let divider = NSBezierPath(); divider.move(to: NSPoint(x: x, y: 10)); divider.line(to: NSPoint(x: x, y: 24))
            divider.lineWidth = 0.5; divider.stroke()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    // Toolbar gaps belong to the toolbar, so clicking them cannot create a new selection behind it.
    override func mouseDown(with event: NSEvent) {}
}

@MainActor
private final class CaptureActionCell: NSButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        CaptureToolbarDrawing.cell(cellFrame, pressed: isHighlighted, focused: controlView.window?.firstResponder === controlView)
        CaptureToolbarDrawing.label(title, in: cellFrame, font: font ?? .systemFont(ofSize: 12),
                                    color: isEnabled ? Preferences.shared.palette.text : Preferences.shared.palette.secondary)
    }
}

@MainActor
private final class CaptureDimensionCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        let height = min(rect.height, ceil(textSize.height))
        return NSRect(x: rect.minX + 4, y: rect.midY - height / 2, width: max(0, rect.width - 8), height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let editing = (controlView as? NSTextField)?.currentEditor() != nil
        CaptureToolbarDrawing.cell(cellFrame, focused: editing)
        super.draw(withFrame: cellFrame, in: controlView)
    }
}

@MainActor
private final class CaptureRatioCell: NSPopUpButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        CaptureToolbarDrawing.cell(cellFrame, pressed: isHighlighted, focused: controlView.window?.firstResponder === controlView)
        CaptureToolbarDrawing.label(title, in: NSRect(x: cellFrame.minX + 5, y: cellFrame.minY, width: 30, height: cellFrame.height))
        let direction: CGFloat = controlView.isFlipped ? 1 : -1
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: cellFrame.maxX - 15, y: cellFrame.midY - direction * 1.5))
        arrow.line(to: NSPoint(x: cellFrame.maxX - 12, y: cellFrame.midY + direction * 1.5))
        arrow.line(to: NSPoint(x: cellFrame.maxX - 9, y: cellFrame.midY - direction * 1.5))
        Preferences.shared.palette.secondary.setStroke(); arrow.lineWidth = 1; arrow.stroke()
    }
}
