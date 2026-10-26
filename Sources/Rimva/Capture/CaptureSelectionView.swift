import AppKit
import RimvaCore

/// Selection geometry uses AppKit points; only the final crop converts to native image pixels.
@MainActor
final class CaptureSelectionView: NSView, NSTextFieldDelegate {
    var onActivate: (() -> Void)?
    var onConfirm: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var toolbarSafeBounds: NSRect { didSet { needsLayout = true } }
    var isWindowMode = false { didSet { refreshLabels(); refresh() } }
    var isScrollingMode = false { didSet { refreshLabels(); refresh() } }
    var isFullScreenMode = false { didSet { selection = isFullScreenMode ? bounds : nil; refresh() } }
    var selectedRect: NSRect? { selection }
    private(set) var selectedWindowIndex: Int?
    var canConfirm: Bool {
        if isWindowMode { return selectedWindowIndex != nil }
        guard let selection, let pixelRect else { return false }
        return isScrollingMode ? selection.width >= 40 && selection.height >= 80 : pixelRect.width >= 1 && pixelRect.height >= 1
    }

    private let image: CGImage?
    private let preview: NSImage?
    private let windowRects: [NSRect]
    private var selection: NSRect?
    private var drag: Drag?
    private var startPoint = NSPoint.zero
    private var startRect = NSRect.zero
    private var tracking: NSTrackingArea?
    private let toolbar = CaptureToolbarSurface()
    private let cancelButton = CaptureActionButton(title: "", target: nil, action: nil)
    private let editorButton = CaptureActionButton(title: "", target: nil, action: nil)
    private let confirmButton = CaptureActionButton(title: "", target: nil, action: nil)
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private let ratioButton = CaptureActionButton(title: "", target: nil, action: nil)
    private let ratioPanel = CaptureToolbarSurface()
    private var ratioButtons: [CaptureActionButton] = []
    private var ratioIndex = 0
    var precisionControlsVisible: Bool { !ratioPanel.isHidden }
    private var pointer: NSPoint?
    private var selectedRatio: CGFloat? { [nil, CGFloat(1), CGFloat(4) / 3, CGFloat(16) / 9][ratioIndex] }

    private enum Drag {
        case create, move, resize(Int)
    }

    init(image: CGImage?, size: NSSize, windowRects: [NSRect]) {
        self.image = image
        preview = image.map { NSImage(cgImage: $0, size: size) }
        self.windowRects = windowRects
        toolbarSafeBounds = NSRect(origin: .zero, size: size)
        super.init(frame: NSRect(origin: .zero, size: size))
        appearance = Preferences.shared.appearance.native
        addSubview(toolbar)
        for button in [cancelButton, editorButton, confirmButton] {
            button.cell = CaptureActionCell(textCell: "")
            button.setButtonType(.momentaryPushIn)
            button.isBordered = false
            button.focusRingType = .none
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.target = self
            toolbar.addSubview(button)
        }
        (cancelButton.cell as? CaptureActionCell)?.symbol = "xmark"
        (editorButton.cell as? CaptureActionCell)?.symbol = "pencil"
        (confirmButton.cell as? CaptureActionCell)?.symbol = "viewfinder"
        cancelButton.action = #selector(cancelSelection)
        editorButton.action = #selector(editSelection)
        editorButton.isEnabled = false
        confirmButton.action = #selector(confirmSelection)
        confirmButton.isEnabled = false
        for field in [widthField, heightField] {
            field.cell = CaptureDimensionCell(textCell: "")
            field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
            field.alignment = .center
            field.isEditable = true; field.isSelectable = true
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
            field.focusRingType = .none
            field.target = self; field.action = #selector(resizeFromFields(_:))
            field.delegate = self
            field.formatter = {
                let formatter = NumberFormatter(); formatter.allowsFloats = false; formatter.minimum = 1
                return formatter
            }()
            toolbar.addSubview(field)
        }
        for button in [ratioButton] {
            let cell = CaptureActionCell(textCell: "")
            button.cell = cell
            button.setButtonType(.momentaryPushIn)
            button.isBordered = false; button.focusRingType = .none
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.target = self
            toolbar.addSubview(button)
        }
        (ratioButton.cell as? CaptureActionCell)?.symbol = "rectangle"
        (ratioButton.cell as? CaptureActionCell)?.showsTitle = false
        ratioButton.action = #selector(toggleRatio)
        addSubview(ratioPanel); ratioPanel.isHidden = true
        for (index, title) in [L("自由"), "1:1", "4:3", "16:9"].enumerated() {
            let button = CaptureActionButton(title: title, target: self, action: #selector(chooseRatio(_:)))
            button.cell = CaptureActionCell(textCell: title)
            button.isBordered = false; button.focusRingType = .none
            button.font = .systemFont(ofSize: 11)
            button.target = self; button.action = #selector(chooseRatio(_:))
            button.tag = index
            button.frame = NSRect(x: 8 + index * 46, y: 8, width: 42, height: 28)
            ratioPanel.addSubview(button); ratioButtons.append(button)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLabels), name: .rimvaLanguageChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance), name: .rimvaThemeChanged, object: nil)
        refreshLabels()
        refreshAppearance()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refreshLabels() {
        cancelButton.title = L("取消")
        cancelButton.toolTip = L("取消 Esc")
        editorButton.title = L("编辑")
        editorButton.toolTip = L("在编辑器中打开")
        editorButton.setAccessibilityLabel(L("在编辑器中打开"))
        editorButton.isHidden = isScrollingMode
        confirmButton.title = isScrollingMode ? L("开始") : L("截图")
        confirmButton.toolTip = isScrollingMode ? L("按回车开始") : L("按回车截图")
        ratioButtons.first?.title = L("自由")
        widthField.setAccessibilityLabel(L("宽度（像素）"))
        heightField.setAccessibilityLabel(L("高度（像素）"))
        widthField.toolTip = L("宽度（像素）")
        heightField.toolTip = L("高度（像素）")
        ratioButton.setAccessibilityLabel(L("选区比例"))
        ratioButton.toolTip = L("选区比例")
        if isWindowMode {
            setAccessibilityLabel(L("窗口截图。单击窗口截图，空格切换区域，Escape 取消。"))
        } else {
            setAccessibilityLabel(isScrollingMode ? L("长截屏选区。拖动选择后按回车开始，Escape 取消。") : L("截图选区。拖动选择，空格切换窗口，回车截图，Escape 取消。"))
        }
        needsLayout = true; needsDisplay = true
        toolbar.needsDisplay = true
    }
    @objc private func refreshAppearance() {
        appearance = Preferences.shared.appearance.native
        for field in [widthField, heightField] { field.textColor = Preferences.shared.palette.text }
        for view in [toolbar, cancelButton, editorButton, confirmButton, ratioButton, ratioPanel, widthField, heightField] { view.needsDisplay = true }
        needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let showPrecision = selection != nil && !isWindowMode && !isFullScreenMode
        let buttons = isScrollingMode ? [cancelButton, confirmButton] : [editorButton, cancelButton, confirmButton]
        // Text width + 14-point icon + 5-point gap + symmetric 8-point padding.
        let actionWidths = buttons.map { ceil($0.attributedTitle.size().width + 35) }
        let precisionWidth: CGFloat = showPrecision ? 162 : 0
        let width = 12 + actionWidths.reduce(0, +) + CGFloat(buttons.count - 1) * 6 + precisionWidth
        toolbar.frame = Self.toolbarFrame(selection: selection, safeBounds: toolbarSafeBounds,
                                          size: NSSize(width: width, height: 40))
        widthField.isHidden = !showPrecision
        heightField.isHidden = !showPrecision
        ratioButton.isHidden = !showPrecision
        toolbar.showsDimensions = showPrecision
        let precisionX: CGFloat = 6
        widthField.frame = NSRect(x: precisionX, y: 6, width: 52, height: 28)
        heightField.frame = NSRect(x: precisionX + 72, y: 6, width: 52, height: 28)
        ratioButton.frame = NSRect(x: precisionX + 128, y: 6, width: 28, height: 28)
        toolbar.multiplicationX = precisionX + 56
        // Keep Cancel beside Capture; precision controls lead the action buttons.
        var buttonX: CGFloat = 6 + precisionWidth
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: buttonX, y: 6, width: actionWidths[index], height: 28)
            buttonX += actionWidths[index] + 6
        }
        if !showPrecision { dismissPrecisionControls() }
        positionPanel(ratioPanel, size: NSSize(width: 196, height: 44), anchor: ratioButton)
    }

    private func positionPanel(_ panel: NSView, size: NSSize, anchor: NSView) {
        let safe = toolbarSafeBounds.insetBy(dx: 12, dy: 12)
        let below = toolbar.frame.minY - size.height - 6
        let y = below >= safe.minY ? below : toolbar.frame.maxY + 6
        let x = toolbar.frame.minX + anchor.frame.minX
        panel.frame = NSRect(x: min(max(safe.minX, x), safe.maxX - size.width),
                            y: min(max(safe.minY, y), safe.maxY - size.height), width: size.width, height: size.height)
    }

    @discardableResult func dismissPrecisionControls() -> Bool {
        let visible = precisionControlsVisible
        ratioPanel.isHidden = true
        if visible { window?.makeFirstResponder(self) }
        return visible
    }

    @objc private func toggleRatio() {
        let show = ratioPanel.isHidden
        dismissPrecisionControls()
        ratioPanel.isHidden = !show
        updateRatioButtons()
    }

    private func updateRatioButtons() {
        for button in ratioButtons {
            (button.cell as? CaptureActionCell)?.selected = button.tag == ratioIndex
            button.needsDisplay = true
        }
    }

    @objc private func chooseRatio(_ sender: NSButton) {
        ratioIndex = sender.tag
        if selectedRatio != nil { applyDimensions(widthField) }
        updateRatioButtons()
        dismissPrecisionControls()
    }

    static func toolbarFrame(selection: NSRect?, safeBounds: NSRect, size: NSSize) -> NSRect {
        let safe = safeBounds.insetBy(dx: 12, dy: 12)
        let x = min(max(safe.minX, (selection?.midX ?? safe.midX) - size.width / 2), safe.maxX - size.width)
        var y = safe.minY
        if let selection {
            let below = selection.minY - 10 - size.height
            let above = selection.maxY + 10
            if below >= safe.minY {
                y = below
            } else if above + size.height <= safe.maxY {
                y = above
            } else {
                // A maximized window has no room outside it. Keep actions inside its lower edge,
                // rather than pushing them into the menu bar or camera housing.
                y = max(safe.minY, selection.minY + 12)
            }
        }
        y = min(max(safe.minY, y), safe.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        if isFullScreenMode { addCursorRect(bounds, cursor: .arrow); return }
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
        selectedWindowIndex = nil
        drag = nil
        refresh()
    }

    func updateWindowSelection(at point: NSPoint) {
        guard isWindowMode else { return }
        selectedWindowIndex = windowRects.firstIndex(where: { $0.contains(point) })
        selection = selectedWindowIndex.map { windowRects[$0].intersection(bounds) }
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
        dismissPrecisionControls()
        onActivate?()
        if !isWindowMode {
            window?.makeKey()
            window?.makeFirstResponder(self)
        }
        guard !isFullScreenMode else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        pointer = point
        if isWindowMode {
            // Resolve the target at the click, even if no hover event arrived first.
            updateWindowSelection(at: point)
            confirmSelection()
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
        if let preview {
            preview.draw(in: bounds)
            NSColor.black.withAlphaComponent(0.38).setFill()
            bounds.fill()
        } else {
            // Window selection stays live; only dim the desktop outside the hovered window.
            let mask = NSBezierPath(rect: bounds)
            if let selection, !selection.isEmpty { mask.appendRect(selection) }
            mask.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.22).setFill()
            mask.fill()
        }
        if let selection, selection.width > 0, selection.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            preview?.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            Preferences.shared.palette.accent.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 2
            outline.stroke()
            if !isWindowMode && !isFullScreenMode {
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
                drawBadge(text, centerX: selection.midX, y: y, fontSize: 11)
            }
        }
        if let pointer, !isWindowMode, !isFullScreenMode, selection == nil || drag != nil { drawMagnifier(at: pointer) }

    }

    func selectedImage() -> CGImage? {
        // Window mode passes its selected window ID to ScreenCaptureKit, never a desktop crop.
        guard !isWindowMode, let image, let pixelRect, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }

    private var pixelRect: CGRect? {
        guard let selection, !selection.isEmpty else { return nil }
        let scaleX = image.map { CGFloat($0.width) / bounds.width } ?? window?.backingScaleFactor ?? 1
        let scaleY = image.map { CGFloat($0.height) / bounds.height } ?? window?.backingScaleFactor ?? 1
        // CGImage crops from the top-left; AppKit selection coordinates start at the bottom-left.
        let left = (selection.minX * scaleX).rounded()
        let right = (selection.maxX * scaleX).rounded()
        let top = ((bounds.height - selection.maxY) * scaleY).rounded()
        let bottom = ((bounds.height - selection.minY) * scaleY).rounded()
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: bounds.width * scaleX, height: bounds.height * scaleY))
    }

    private func refresh() {
        toolbar.isHidden = isWindowMode
        if isWindowMode { dismissPrecisionControls() }
        confirmButton.isEnabled = canConfirm
        editorButton.isEnabled = canConfirm
        needsLayout = true
        if let pixelRect {
            widthField.integerValue = Int(pixelRect.width); heightField.integerValue = Int(pixelRect.height)
        }
        needsDisplay = true
        invalidateCursorRects()
    }

    override func keyDown(with event: NSEvent) {
        guard [123, 124, 125, 126].contains(event.keyCode), !isWindowMode, !isFullScreenMode,
              let image, var selection else { super.keyDown(with: event); return }
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
        applyDimensions(sender)
        dismissPrecisionControls()
    }

    private func applyDimensions(_ sender: Any?) {
        guard let image, var selection else { return }
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
        refresh()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        (notification.object as? NSTextField)?.needsDisplay = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        (notification.object as? NSTextField)?.needsDisplay = true
        applyDimensions(notification.object)
    }

    private func drawMagnifier(at point: NSPoint) {
        guard let image else { return }
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
        let palette = Preferences.shared.palette
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: palette.secondary]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = size.width + 16
        let box = NSRect(x: min(max(12, centerX - width / 2), bounds.width - width - 12), y: y, width: width, height: size.height + 12)
        let shape = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        palette.background.setFill(); shape.fill()
        palette.separator.setStroke(); shape.lineWidth = 0.5; shape.stroke()
        (text as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + 6), withAttributes: attributes)
    }

    @objc private func cancelSelection() { onCancel?() }
    @objc private func editSelection() { if canConfirm { onConfirm?(true) } else { NSSound.beep() } }
    @objc private func confirmSelection() { if canConfirm { onConfirm?(false) } else { NSSound.beep() } }
}

@MainActor
private enum CaptureToolbarDrawing {
    static func cell(_ rect: NSRect, pressed: Bool = false, focused: Bool = false) {
        let palette = Preferences.shared.palette
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
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
    var multiplicationX: CGFloat = 0 { didSet { if oldValue != multiplicationX { needsDisplay = true } } }
    var showsDimensions = false { didSet { if oldValue != showsDimensions { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        let palette = Preferences.shared.palette
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        // Use exactly the launcher's theme colors; screenshots and mockups can carry different color profiles.
        palette.background.setFill(); shape.fill()
        palette.separator.setStroke(); shape.lineWidth = 0.5; shape.stroke()
        if showsDimensions {
            // Use the mathematical multiplication glyph, centered in the same 28-point control row.
            CaptureToolbarDrawing.label("×", in: NSRect(x: multiplicationX, y: 6, width: 12, height: 28),
                                        font: .systemFont(ofSize: 17, weight: .regular), color: palette.secondary)
        }

    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    // Toolbar gaps belong to the toolbar, so clicking them cannot create a new selection behind it.
    override func mouseDown(with event: NSEvent) {}
}

@MainActor
private final class CaptureActionButton: NSButton {
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        (cell as? CaptureActionCell)?.hovered = true; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        (cell as? CaptureActionCell)?.hovered = false; needsDisplay = true
    }
}

@MainActor
private final class CaptureActionCell: NSButtonCell {
    var symbol = ""
    var showsTitle = true
    var hovered = false
    var selected = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame rect: NSRect, in controlView: NSView) {
        let palette = Preferences.shared.palette
        let focused = controlView.window?.firstResponder === controlView
        let active = isEnabled && (hovered || isHighlighted || focused || selected)
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
        (active ? palette.selection : palette.elevated).setFill(); shape.fill()
        (active ? palette.accent : palette.separator).setStroke(); shape.lineWidth = 0.5; shape.stroke()
        let foreground = isEnabled ? palette.text : palette.secondary.withAlphaComponent(0.5)
        let labelFont = font ?? .systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: foreground]
        let textSize = showsTitle ? (title as NSString).size(withAttributes: attributes) : .zero
        let iconSize: CGFloat = 14
        let hasIcon = !symbol.isEmpty
        let groupWidth = textSize.width + (hasIcon ? iconSize + (showsTitle ? 5 : 0) : 0)
        let startX = rect.midX - groupWidth / 2
        if hasIcon {
            drawSymbol(at: NSPoint(x: startX, y: rect.midY - iconSize / 2), color: foreground, flipped: controlView.isFlipped)
        }
        if showsTitle {
            (title as NSString).draw(at: NSPoint(x: startX + (hasIcon ? iconSize + 5 : 0), y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }
    }

    private func drawSymbol(at origin: NSPoint, color: NSColor, flipped: Bool) {
        // A shared 14-point grid and stroke avoids SF Symbols' differing optical insets.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y + (flipped ? 14 : 0))
        if flipped { transform.scaleX(by: 1, yBy: -1) }
        transform.concat()
        let path = NSBezierPath()
        path.lineWidth = 1.25; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch symbol {
        case "xmark":
            path.move(to: NSPoint(x: 1, y: 1)); path.line(to: NSPoint(x: 13, y: 13))
            path.move(to: NSPoint(x: 1, y: 13)); path.line(to: NSPoint(x: 13, y: 1))
        case "pencil":
            path.move(to: NSPoint(x: 1, y: 1))
            for point in [NSPoint(x: 2, y: 5), NSPoint(x: 10, y: 13), NSPoint(x: 13, y: 10), NSPoint(x: 5, y: 2)] {
                path.line(to: point)
            }
            path.close()
            path.move(to: NSPoint(x: 8, y: 11)); path.line(to: NSPoint(x: 11, y: 8))
        case "viewfinder":
            for (x, y, dx, dy) in [(1.0, 1.0, 1.0, 1.0), (13.0, 1.0, -1.0, 1.0),
                                    (13.0, 13.0, -1.0, -1.0), (1.0, 13.0, 1.0, -1.0)] {
                path.move(to: NSPoint(x: x, y: y + 3 * dy))
                path.line(to: NSPoint(x: x, y: y)); path.line(to: NSPoint(x: x + 3 * dx, y: y))
            }
        case "rectangle":
            path.appendRoundedRect(NSRect(x: 1, y: 3, width: 12, height: 8), xRadius: 1, yRadius: 1)
        default: return
        }
        color.setStroke(); path.stroke()
    }

}

@MainActor
private final class CaptureDimensionCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = ("0" as NSString).size(withAttributes: [.font: font ?? NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)])
        let height = min(rect.height, ceil(textSize.height))
        return NSRect(x: rect.minX + 4, y: rect.midY - height / 2, width: max(0, rect.width - 8), height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let editing = (controlView as? NSTextField)?.currentEditor() != nil
        CaptureToolbarDrawing.cell(cellFrame, focused: editing)
        if editing {
            super.draw(withFrame: cellFrame, in: controlView)
        } else {
            CaptureToolbarDrawing.label(stringValue, in: cellFrame,
                                        font: font ?? .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        }
    }
}
