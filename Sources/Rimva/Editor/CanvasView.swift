import AppKit
import SwiftUI
import RimvaCore

struct CanvasView: NSViewRepresentable {
    @ObservedObject var session: EditorSession
    var onImport: (URL) -> Void
    var onPaste: () -> Void
    func makeNSView(context: Context) -> EditorCanvas {
        let view = EditorCanvas(session: session)
        view.onImport = onImport; view.onPaste = onPaste
        return view
    }
    func updateNSView(_ view: EditorCanvas, context: Context) {
        if session.tool != .text && view.textEditor != nil { view.finishTextEditing() }
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class EditorCanvas: NSView, NSTextViewDelegate {
    private let session: EditorSession
    var onImport: ((URL) -> Void)?
    var onPaste: (() -> Void)?
    private var origin = CGPoint.zero
    private var scale: CGFloat = 1
    private var imageArea = CGRect.zero
    private var cropOrigin = CGPoint.zero
    private var dragStart = CGPoint.zero
    private var initialMark: Annotation?
    private var resizeHandle: Int?
    private var draggingCrop = false
    private var movingCrop = false
    private var originalCrop = CGRect.zero
    private var cropHandle: Int?
    private var drawingNew = false
    private(set) var textEditor: NSTextView?
    private var editingID: UUID?
    private var renderingError: String?
    private var pan = CGPoint.zero
    private var panStart: CGPoint?
    private var tracking: NSTrackingArea?
    private var hoveredHandle: CGPoint?
    private weak var displayedImage: CGImage?
    private static let resizeCursors: [NSCursor] = [false, true].map { mirrored in
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: mirrored ? 20 - x : x, y: y) }
            let arrow = NSBezierPath()
            arrow.move(to: point(4, 4)); arrow.line(to: point(16, 16))
            arrow.move(to: point(4, 10)); arrow.line(to: point(4, 4)); arrow.line(to: point(10, 4))
            arrow.move(to: point(10, 16)); arrow.line(to: point(16, 16)); arrow.line(to: point(16, 10))
            NSColor.white.setStroke(); arrow.lineWidth = 4; arrow.stroke()
            NSColor.black.setStroke(); arrow.lineWidth = 1.5; arrow.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        session.finishEditing = { [weak self] in self?.finishTextEditing() }
        setAccessibilityLabel(L("图片编辑画布"))
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // SwiftUI can resize the native view after its first draw. Recompute fit and
        // hit coordinates even when shrinking the view exposes no new dirty region.
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = session.image, let context = NSGraphicsContext.current?.cgContext else { return }
        let size = session.outputSize
        guard size.width > 0, size.height > 0 else { return }
        if displayedImage !== image { pan = .zero; displayedImage = image }
        // Reserve the same control space in every tool to keep drag coordinates stable.
        let top: CGFloat = 64
        let available = CGSize(width: max(1, bounds.width - 64), height: max(1, bounds.height - top - 48))
        let backing = convertToBacking(CGSize(width: 1, height: 1)).width
        let fit = min(1 / backing, min(available.width / size.width, available.height / size.height))
        scale = session.zoom.map { $0 / backing } ?? fit
        let zoom = scale * backing
        if abs(session.displayedZoom - zoom) > 0.0001 {
            DispatchQueue.main.async { [weak self] in self?.session.displayedZoom = zoom }
        }
        let horizontal = max(0, (size.width * scale - available.width) / 2)
        let vertical = max(0, (size.height * scale - available.height) / 2)
        pan.x = min(horizontal, max(-horizontal, pan.x))
        pan.y = min(vertical, max(-vertical, pan.y))
        origin = CGPoint(x: (bounds.width - size.width * scale) / 2 + pan.x,
                         y: top + (available.height - size.height * scale) / 2 + pan.y)
        cropOrigin = session.state.crop?.origin ?? .zero
        imageArea = ImageRenderer.contentRect(image: image, state: session.state, style: session.style)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        var visibleState = session.state
        if let editingID { visibleState.annotations.removeAll { $0.id == editingID } }
        let appearance: RenderAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        do { try ImageRenderer.draw(image: image, state: visibleState, style: session.style, appearance: appearance, in: context) }
        catch {
            let message = error.localizedDescription
            if renderingError != message { renderingError = message; DispatchQueue.main.async { [weak self] in self?.session.notify(message) } }
        }
        context.restoreGState()
        if session.tool == .crop, let crop = session.pendingCrop { drawCrop(crop, context: context) }
        else if let mark = session.selected, mark.id != editingID { drawSelection(mark, context: context) }
        positionTextEditor()
    }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (imageArea.minX + p.x - cropOrigin.x) * scale,
                y: origin.y + (imageArea.minY + p.y - cropOrigin.y) * scale)
    }
    private func imagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale - imageArea.minX + cropOrigin.x,
                y: (p.y - origin.y) / scale - imageArea.minY + cropOrigin.y)
    }
    private func viewRect(_ rect: CGRect) -> CGRect { CGRect(origin: viewPoint(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale)) }
    private var sourceBounds: CGRect {
        guard let image = session.image else { return .zero }
        return session.state.crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }
    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(sourceBounds.maxX, max(sourceBounds.minX, p.x)), y: min(sourceBounds.maxY, max(sourceBounds.minY, p.y)))
    }
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }
    private func drawHandle(_ p: CGPoint, context: CGContext) {
        let side: CGFloat = hoveredHandle.map { hypot($0.x - p.x, $0.y - p.y) < 1 } == true ? 10 : 8
        let rect = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in: rect)
        context.setStrokeColor(Preferences.shared.palette.accent.cgColor); context.setLineWidth(1); context.strokeEllipse(in: rect)
    }
    private func drawSelection(_ mark: Annotation, context: CGContext) {
        let rect = viewRect(mark.rect)
        context.setStrokeColor(Preferences.shared.palette.accent.cgColor); context.setLineWidth(1)
        if mark.kind == .arrow { drawHandle(viewPoint(mark.start), context: context); drawHandle(viewPoint(mark.end), context: context) }
        else { context.stroke(rect.insetBy(dx: -3, dy: -3)); corners(mark.rect).forEach { drawHandle(viewPoint($0), context: context) } }
    }
    private func drawCrop(_ crop: CGRect, context: CGContext) {
        let all = viewRect(sourceBounds), selection = viewRect(crop)
        let mask = CGMutablePath(); mask.addRect(all); mask.addRect(selection)
        context.addPath(mask); context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor); context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(1); context.stroke(selection)
        corners(crop).forEach { drawHandle(viewPoint($0), context: context) }
    }

    override func mouseDown(with event: NSEvent) {
        guard session.image != nil else { return }
        finishTextEditing()
        window?.makeFirstResponder(self)
        let view = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) {
            panStart = view; NSCursor.closedHand.set(); return
        }
        let point = clamped(imagePoint(view))
        guard viewRect(sourceBounds).insetBy(dx: -8, dy: -8).contains(view) else { session.selectedID = nil; return }
        dragStart = point
        if session.tool == .crop {
            originalCrop = session.pendingCrop ?? sourceBounds
            cropHandle = corners(originalCrop).firstIndex { hypot(viewPoint($0).x - view.x, viewPoint($0).y - view.y) < 9 }
            movingCrop = cropHandle == nil && originalCrop.contains(point) && originalCrop != sourceBounds
            draggingCrop = true
            if !movingCrop && cropHandle == nil { session.pendingCrop = CGRect(origin: point, size: .zero) }
            return
        }
        if session.tool == .select {
            if let selected = session.selected {
                let handles = selected.kind == .arrow ? [selected.start, selected.end] : corners(selected.rect)
                if let index = handles.firstIndex(where: { hypot(viewPoint($0).x - view.x, viewPoint($0).y - view.y) < 9 }) {
                    session.beginInteraction(); initialMark = selected; resizeHandle = index; return
                }
            }
            let hit = session.state.annotations.reversed().first { mark in
                if mark.kind == .arrow {
                    let a = viewPoint(mark.start), b = viewPoint(mark.end)
                    let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                    let t = length > 0 ? min(1, max(0, ((view.x-a.x)*dx + (view.y-a.y)*dy) / length)) : 0
                    return hypot(view.x-a.x-t*dx, view.y-a.y-t*dy) < 8
                }
                return viewRect(mark.rect).insetBy(dx: -6, dy: -6).contains(view)
            }
            session.selectedID = hit?.id
            if let hit {
                session.colorHex = hit.colorHex; session.lineWidth = hit.lineWidth; session.fontSize = hit.fontSize
                if event.clickCount == 2 && hit.kind == .text { session.tool = .text; beginTextEditing(hit); return }
                session.beginInteraction(); initialMark = hit; resizeHandle = nil
            }
            return
        }
        guard let kind = session.tool.annotation else { return }
        session.beginInteraction()
        let number = (session.state.annotations.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1
        let size: CGSize = kind == .text ? CGSize(width: 360, height: max(54, session.fontSize * 1.6)) : kind == .number ? CGSize(width: 48, height: 48) : .zero
        let rect = Self.placementRect(at: point, size: size, within: sourceBounds)
        let mark = Annotation(kind: kind, start: rect.origin, end: CGPoint(x: rect.maxX, y: rect.maxY), colorHex: session.colorHex, lineWidth: session.lineWidth, fontSize: session.fontSize, number: number)
        session.state.annotations.append(mark); session.selectedID = mark.id
        if kind == .text { beginTextEditing(mark) }
        else if kind != .number { initialMark = mark; drawingNew = true }
    }

    override func mouseDragged(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        if let panStart {
            pan.x += view.x - panStart.x; pan.y += view.y - panStart.y
            self.panStart = view; needsDisplay = true; return
        }
        let point = clamped(imagePoint(view))
        if draggingCrop {
            var rect: CGRect
            if movingCrop {
                let dx = min(sourceBounds.maxX - originalCrop.maxX, max(sourceBounds.minX - originalCrop.minX, point.x - dragStart.x))
                let dy = min(sourceBounds.maxY - originalCrop.maxY, max(sourceBounds.minY - originalCrop.minY, point.y - dragStart.y))
                rect = originalCrop.offsetBy(dx: dx, dy: dy)
            } else if let cropHandle {
                let opposite = corners(originalCrop)[3-cropHandle]
                rect = CGRect(x: min(opposite.x, point.x), y: min(opposite.y, point.y), width: abs(opposite.x-point.x), height: abs(opposite.y-point.y))
            } else { rect = CGRect(x: min(dragStart.x, point.x), y: min(dragStart.y, point.y), width: abs(point.x-dragStart.x), height: abs(point.y-dragStart.y)) }
            session.pendingCrop = rect.integral.intersection(sourceBounds)
            return
        }
        guard let initialMark, let index = session.state.annotations.firstIndex(where: { $0.id == initialMark.id }) else { return }
        var mark = initialMark
        if drawingNew { mark.end = point }
        else if let resizeHandle {
            if mark.kind == .arrow {
                if resizeHandle == 0 { mark.start = point } else { mark.end = point }
            } else {
                let anchor = corners(initialMark.rect)[3-resizeHandle]
                mark.start = CGPoint(x: min(anchor.x, point.x), y: min(anchor.y, point.y))
                mark.end = CGPoint(x: max(anchor.x, point.x), y: max(anchor.y, point.y))
            }
        }
        else {
            let dx = min(sourceBounds.maxX-initialMark.rect.maxX, max(sourceBounds.minX-initialMark.rect.minX, point.x-dragStart.x))
            let dy = min(sourceBounds.maxY-initialMark.rect.maxY, max(sourceBounds.minY-initialMark.rect.minY, point.y-dragStart.y))
            mark = initialMark.moved(by: CGSize(width: dx, height: dy))
        }
        session.state.annotations[index] = mark
    }

    override func mouseUp(with event: NSEvent) {
        if panStart != nil { panStart = nil; window?.invalidateCursorRects(for: self); return }
        if drawingNew, let initialMark, let index = session.state.annotations.firstIndex(where: { $0.id == initialMark.id }) {
            let mark = session.state.annotations[index]
            let tooSmall = mark.kind == .arrow ? hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) < 2
                : mark.rect.width < 2 || mark.rect.height < 2
            if tooSmall { session.state.annotations.remove(at: index); session.selectedID = nil }
        }
        initialMark = nil; resizeHandle = nil; drawingNew = false; draggingCrop = false; cropHandle = nil
        if textEditor == nil { session.endInteraction() }
    }

    static func placementRect(at point: CGPoint, size: CGSize, within bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        return CGRect(x: max(bounds.minX, min(point.x, bounds.maxX - size.width)),
                      y: max(bounds.minY, min(point.y, bounds.maxY - size.height)), width: size.width, height: size.height)
    }

    private func beginTextEditing(_ mark: Annotation) {
        session.beginInteraction()
        editingID = mark.id
        let text = NSTextView(frame: viewRect(mark.rect))
        text.isRichText = false; text.drawsBackground = false; text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.font = ImageRenderer.annotationFont(size: mark.fontSize * scale)
        text.textColor = ImageRenderer.color(hex: mark.colorHex)
        text.insertionPointColor = text.textColor ?? .labelColor
        text.string = mark.text; text.delegate = self
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel(L("标注文字"))
        textEditor = text; addSubview(text); window?.makeFirstResponder(text)
        needsDisplay = true
    }
    private func positionTextEditor() {
        guard let text = textEditor, let mark = session.state.annotations.first(where: { $0.id == editingID }) else { return }
        text.frame = viewRect(mark.rect)
        text.font = ImageRenderer.annotationFont(size: mark.fontSize * scale)
        text.textColor = ImageRenderer.color(hex: mark.colorHex)
    }
    func textDidChange(_ notification: Notification) {
        guard let text = textEditor, let index = session.state.annotations.firstIndex(where: { $0.id == editingID }) else { return }
        session.beginInteraction()
        var mark = session.state.annotations[index]; mark.text = text.string
        let attributes = try? ImageRenderer.annotationTextAttributes(colorHex: mark.colorHex, fontSize: mark.fontSize)
        let height = (mark.text as NSString).boundingRect(with: CGSize(width: max(1, mark.rect.width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height
        let fitted = Self.placementRect(at: mark.start, size: CGSize(width: mark.rect.width, height: max(mark.fontSize * 1.6, ceil(height) + 4)), within: sourceBounds)
        mark.start = fitted.origin; mark.end = CGPoint(x: fitted.maxX, y: fitted.maxY)
        session.state.annotations[index] = mark
    }
    func textDidEndEditing(_ notification: Notification) { finishTextEditing() }
    func finishTextEditing() {
        guard let text = textEditor else { return }
        let id = editingID
        text.delegate = nil; textEditor = nil; editingID = nil
        text.removeFromSuperview()
        if let id, let index = session.state.annotations.firstIndex(where: { $0.id == id }), session.state.annotations[index].text.isEmpty { session.state.annotations.remove(at: index); session.selectedID = nil }
        session.endInteraction()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            session.zoom = min(8, max(0.05, session.displayedZoom * exp(event.scrollingDeltaY * 0.015)))
        } else {
            pan.x += event.scrollingDeltaX
            pan.y += event.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        session.zoom = min(8, max(0.05, session.displayedZoom * (1 + event.magnification)))
    }

    private var activeHandles: [CGPoint] {
        if session.tool == .crop, let crop = session.pendingCrop { return corners(crop).map(viewPoint) }
        guard let mark = session.selected else { return [] }
        return (mark.kind == .arrow ? [mark.start, mark.end] : corners(mark.rect)).map(viewPoint)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredHandle = activeHandles.first { hypot($0.x - point.x, $0.y - point.y) <= 10 }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hoveredHandle = nil; needsDisplay = true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: session.tool == .select ? .arrow : session.tool == .text ? .iBeam : .crosshair)
        if session.tool == .select {
            for mark in session.state.annotations { addCursorRect(viewRect(mark.rect), cursor: .openHand) }
        } else if session.tool == .crop, let crop = session.pendingCrop { addCursorRect(viewRect(crop), cursor: .openHand) }
        for (index, point) in activeHandles.enumerated() {
            let cursor = session.selected?.kind == .arrow ? NSCursor.crosshair : Self.resizeCursors[[0, 3].contains(index) ? 1 : 0]
            addCursorRect(CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), cursor: cursor)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: session.deleteSelected()
        case 53: session.selectTool(.select); session.selectedID = nil
        case 36, 76: if session.tool == .crop { session.applyCrop() } else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }
    @objc func paste(_ sender: Any?) { onPaste?() }
    @objc func undo(_ sender: Any?) { finishTextEditing(); session.undo() }
    @objc func redo(_ sender: Any?) { finishTextEditing(); session.redo() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first { onImport?(url); return true }
        return false
    }
}
