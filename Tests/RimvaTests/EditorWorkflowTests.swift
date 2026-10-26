import AppKit
import Carbon
import XCTest
import RimvaCore
@testable import Rimva

final class EditorWorkflowTests: XCTestCase {
    private var originalStyle: BackgroundStyle?

    @MainActor override func setUp() async throws {
        // Command-line XCTest has no application host, but Preferences uses AppKit's NSApp.
        _ = NSApplication.shared
        originalStyle = Preferences.shared.defaultStyle
    }

    @MainActor override func tearDown() async throws {
        if let originalStyle { Preferences.shared.defaultStyle = originalStyle }
    }

    private func image(width: Int = 640, height: Int = 480) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor func testQuickCaptureSavesWithoutLeavingUnsavedDocument() throws {
        let preferences = Preferences.shared
        let originalCopy = preferences.automaticCopy
        let originalSave = preferences.automaticSave
        let originalOpen = preferences.opensEditorAfterCapture
        let originalFolder = preferences.saveFolder
        let originalURL = preferences.lastSavedURL
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/capture-test-\(UUID().uuidString)")
        defer {
            preferences.automaticCopy = originalCopy
            preferences.automaticSave = originalSave
            preferences.opensEditorAfterCapture = originalOpen
            preferences.saveFolder = originalFolder
            preferences.lastSavedURL = originalURL
            try? FileManager.default.removeItem(at: folder)
        }
        preferences.automaticCopy = false
        preferences.automaticSave = true
        preferences.opensEditorAfterCapture = false
        preferences.saveFolder = folder
        let controller = AppController(hotKey: HotKey(registersShortcuts: false))
        controller.showEditor()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Rimva" && $0.isVisible })
        defer { window.close() }
        for _ in 0..<2 {
            controller.finishCapture(try image())
            let saved = try XCTUnwrap(preferences.lastSavedURL)
            XCTAssertNotNil(try ImageExporter.read(saved))
            XCTAssertNil(controller.session.image)
            XCTAssertFalse(controller.session.hasUnsavedChanges)
            XCTAssertFalse(window.isVisible)
        }
        controller.finishCapture(try image(), opensEditor: true)
        XCTAssertNotNil(controller.session.image)
        XCTAssertTrue(window.isVisible)
    }

    @MainActor func testLoginLaunchDetectionKeepsManualLaunchDistinct() {
        XCTAssertFalse(AppController.isLoginLaunch(nil))
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(AppController.isLoginLaunch(event))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(AppController.isLoginLaunch(event))
    }

    @MainActor func testToolShortcutsWorkBeforeCanvasFocusAndKeepCommandKeys() async throws {
        let session = EditorSession()
        session.load(try image())
        let window = EditorWindow(contentRect: CGRect(x: 0, y: 0, width: 1008, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.session = session
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        let canvas = EditorCanvas(session: session)
        container.addSubview(canvas)
        XCTAssertTrue(window.makeFirstResponder(nil))
        func press(_ key: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            window.sendEvent(event)
        }
        for (key, tool) in [("a", EditorTool.arrow), ("r", .rectangle), ("t", .text), ("n", .number), ("m", .redact), ("c", .crop), ("v", .select)] {
            try press(key)
            XCTAssertEqual(session.tool, tool)
            if tool == .crop { XCTAssertNotNil(session.pendingCrop) }
        }
        XCTAssertNil(session.pendingCrop)
        XCTAssertTrue(window.makeFirstResponder(canvas))
        try press("b")
        XCTAssertTrue(session.backgroundShown)
        try press("b")
        XCTAssertFalse(session.backgroundShown)
        for modifiers: NSEvent.ModifierFlags in [.command, .option, .control] {
            try press("t", modifiers: modifiers)
            XCTAssertEqual(session.tool, .select)
        }
        try press("R", modifiers: .capsLock)
        XCTAssertEqual(session.tool, .rectangle)
    }

    @MainActor func testToolShortcutsDoNotInterruptTextEditing() async throws {
        let session = EditorSession()
        session.load(try image())
        session.selectTool(.text)
        let window = EditorWindow(contentRect: CGRect(x: 0, y: 0, width: 1008, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.session = session
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 50))
        container.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "b",
                                                 charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        window.sendEvent(event)
        XCTAssertEqual(session.tool, .text)
        XCTAssertFalse(session.backgroundShown)
        XCTAssertEqual(text.string, "b")
    }

    func testPNGExportPreservesTransparentRoundedCornersWithoutBackground() throws {
        let output = try ImageRenderer.render(image: image(width: 40, height: 30), state: EditState(),
                                              style: BackgroundStyle(enabled: false, radius: 10))
        let png = try XCTUnwrap(NSBitmapImageRep(data: ImageExporter.png(output)))
        XCTAssertEqual(png.pixelsWide, 40)
        XCTAssertEqual(png.pixelsHigh, 30)
        XCTAssertEqual(try XCTUnwrap(png.colorAt(x: 0, y: 0)).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(png.colorAt(x: 20, y: 15)).alphaComponent, 1)
    }

    @MainActor func testSavedStateFollowsUndoAndRedo() async throws {
        let session = EditorSession()
        session.load(try image())
        XCTAssertTrue(session.hasUnsavedChanges)
        session.markSaved(to: URL(fileURLWithPath: "/test.png"))
        XCTAssertFalse(session.hasUnsavedChanges)
        session.beginInteraction()
        session.state.annotations.append(Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 40, y: 50)))
        session.endInteraction()
        XCTAssertTrue(session.hasUnsavedChanges)
        session.undo()
        XCTAssertFalse(session.hasUnsavedChanges)
        session.redo()
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    @MainActor func testSettingsAndEditorShareStyleAndUndoAcrossBothDirections() async throws {
        let preferences = Preferences.shared
        let session = EditorSession()
        session.load(try image())
        let initial = session.style
        session.beginInteraction()
        for padding in [4.0, 8, 12] { session.style.padding = padding }
        session.endInteraction()
        XCTAssertEqual(preferences.defaultStyle, session.style)
        session.undo()
        XCTAssertEqual(session.style, initial)
        XCTAssertEqual(preferences.defaultStyle, initial)
        session.redo()
        XCTAssertEqual(preferences.defaultStyle.padding, 12)

        session.beginInteraction()
        for padding in [16.0, 20, 24] { preferences.defaultStyle.padding = padding }
        session.endInteraction()
        session.undo()
        XCTAssertEqual(session.style.padding, 12)
        XCTAssertEqual(preferences.defaultStyle.padding, 12)

        preferences.defaultStyle = BackgroundStyle(padding: 20, source: .image,
                                                   lightImagePath: "day.png", darkImagePath: "night.png")
        XCTAssertEqual(session.style, preferences.defaultStyle)
        XCTAssertEqual(session.style.darkImagePath, "night.png")
        session.undo()
        XCTAssertEqual(session.style.padding, 12)
        XCTAssertEqual(preferences.defaultStyle, session.style)
        session.load(try image(width: 80, height: 60))
        XCTAssertEqual(session.style, preferences.defaultStyle)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor func testClickAndDiscardedShapeDoNotConsumeUndo() async throws {
        let session = EditorSession()
        session.load(try image())
        session.beginInteraction(); session.endInteraction()
        XCTAssertFalse(session.canUndo)
        session.beginInteraction()
        session.state.annotations.append(Annotation(kind: .arrow, start: .zero, end: .zero))
        session.state.annotations.removeAll()
        session.endInteraction()
        XCTAssertFalse(session.canUndo)
        session.changeStyle { $0.padding += 10 }
        session.undo()
        XCTAssertTrue(session.canRedo)
        session.beginInteraction(); session.endInteraction()
        XCTAssertTrue(session.canRedo)
    }

    @MainActor func testNoOpStyleAndSelectionDoNotCreateHistory() async throws {
        let session = EditorSession()
        session.load(try image())
        let mark = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 20, y: 30))
        session.state.annotations = [mark]
        session.selectedID = mark.id
        session.updateSelected { $0.colorHex = mark.colorHex }
        session.changeStyle { $0.padding = session.style.padding }
        XCTAssertFalse(session.canUndo)
    }

    @MainActor func testCopyTracksContentAndUndoRestoresClipboardStatus() async throws {
        let session = EditorSession()
        session.load(try image())
        session.markCopied()
        XCTAssertFalse(session.clipboardIsStale)
        XCTAssertTrue(session.hasUnsavedChanges)
        session.changeStyle { $0.enabled.toggle() }
        session.refreshClipboardStatus()
        XCTAssertTrue(session.clipboardIsStale)
        session.undo(); session.refreshClipboardStatus()
        XCTAssertFalse(session.clipboardIsStale)
    }

    @MainActor func testReplacingImageClearsDocumentSpecificState() async throws {
        let session = EditorSession()
        session.load(try image())
        session.markSaved(to: URL(fileURLWithPath: "/test.png"))
        session.markCopied()
        session.changeStyle { $0.padding += 10 }
        session.zoom = 2
        session.load(try image(width: 100, height: 100))
        XCTAssertNil(session.savedURL)
        XCTAssertNil(session.zoom)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        XCTAssertFalse(session.clipboardIsStale)
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    @MainActor func testAppearanceChangeTracksTheRenderedBackground() async throws {
        let preferences = Preferences.shared
        let original = preferences.appearance
        defer { preferences.appearance = original }
        preferences.appearance = .light
        let session = EditorSession()
        session.load(try image())
        session.style = BackgroundStyle(source: .image, lightImagePath: "day.png", darkImagePath: "night.png")
        session.markSaved(to: URL(fileURLWithPath: "/test.png")); session.markCopied()
        preferences.appearance = .dark
        session.refreshClipboardStatus()
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(session.clipboardIsStale)
        preferences.appearance = .light
        session.refreshClipboardStatus()
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertFalse(session.clipboardIsStale)
    }

    @MainActor func testTextPlacementFitsAtEdgesAndInsideCrop() async {
        for bounds in [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 100, y: 120, width: 30, height: 20)] {
            let rect = EditorCanvas.placementRect(at: CGPoint(x: bounds.maxX, y: bounds.maxY),
                                                 size: CGSize(width: 360, height: 54), within: bounds)
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertTrue(bounds.contains(rect))
        }
    }

    @MainActor func testWindowSelectionWaitsForCaptureActionAndKeepsClickedTarget() throws {
        let view = CaptureSelectionView(image: try image(), size: CGSize(width: 320, height: 240),
                                        windowRects: [CGRect(x: 20, y: 20, width: 100, height: 100),
                                                      CGRect(x: 150, y: 20, width: 100, height: 100)])
        view.isWindowMode = true
        var actions: [Bool] = []
        view.onConfirm = { actions.append($0) }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 40, y: 40),
                                                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        XCTAssertTrue(actions.isEmpty)
        let selected = view.selectedRect
        view.updateWindowSelection(at: CGPoint(x: 180, y: 40))
        XCTAssertEqual(view.selectedRect, selected)
        let buttons = view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        try XCTUnwrap(buttons.first { $0.accessibilityLabel() == L("在编辑器中打开") }).performClick(nil)
        try XCTUnwrap(buttons.first { $0.title == L("截图") }).performClick(nil)
        XCTAssertEqual(actions, [true, false])
    }

    @MainActor func testCapturePanelEscapeCancelsWithSelectionButtonAndDimensionFocus() throws {
        let view = CaptureSelectionView(image: try image(), size: CGSize(width: 640, height: 480),
                                        windowRects: [CGRect(x: 20, y: 20, width: 200, height: 160)])
        view.isWindowMode = true
        view.updateWindowSelection(at: CGPoint(x: 40, y: 40))
        view.isWindowMode = false
        let panel = CapturePanel(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        defer { panel.close() }
        view.layoutSubtreeIfNeeded()
        let toolbar = try XCTUnwrap(view.subviews.first)
        let cancel = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.title == L("取消") })
        let width = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSTextField }.first)
        let ratio = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == L("选区比例") })
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil,
                                                  characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53))
        var cancellations = 0
        panel.onCancel = { cancellations += 1 }
        view.onCancel = { cancellations += 1 }
        for responder in [nil, view, cancel, width] as [NSResponder?] {
            XCTAssertTrue(panel.makeFirstResponder(responder))
            if responder === width { XCTAssertTrue(panel.firstResponder is NSTextView) }
            let previous = cancellations
            panel.sendEvent(escape)
            XCTAssertEqual(cancellations, previous + 1, "Escape must cancel regardless of the focused control")
        }
        ratio.performClick(nil)
        XCTAssertTrue(view.precisionControlsVisible)
        let previous = cancellations
        panel.sendEvent(escape)
        XCTAssertEqual(cancellations, previous + 1, "An open ratio panel must not consume Escape")
        cancel.performClick(nil)
        XCTAssertEqual(cancellations, previous + 2, "Cancel and Escape must use the same cancellation callback")
    }

    @MainActor func testFullScreenSelectionKeepsWholeImage() throws {
        let view = CaptureSelectionView(image: try image(), size: CGSize(width: 320, height: 240), windowRects: [])
        view.isFullScreenMode = true
        XCTAssertTrue(view.canConfirm)
        XCTAssertEqual(view.selectedImage()?.width, 640)
        XCTAssertEqual(view.selectedImage()?.height, 480)
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                isARepeat: false, keyCode: 124))
        view.keyDown(with: right)
        XCTAssertEqual(view.selectedRect, view.bounds)
    }

    @MainActor func testCaptureToolbarAvoidsNotchDockAndScreenEdges() {
        // Simulate a notched laptop with a visible Dock, including a full-screen target.
        let safe = CGRect(x: 0, y: 80, width: 1512, height: 864)
        let size = CGSize(width: 240, height: 76)
        for selection in [CGRect(x: 0, y: 0, width: 1512, height: 982),
                          CGRect(x: 0, y: 0, width: 1512, height: 944),
                          CGRect(x: 0, y: 900, width: 100, height: 82),
                          CGRect(x: 1450, y: 0, width: 62, height: 40)] {
            let frame = CaptureSelectionView.toolbarFrame(selection: selection, safeBounds: safe, size: size)
            XCTAssertTrue(safe.insetBy(dx: 12, dy: 12).contains(frame))
            if selection.height > 900 { XCTAssertEqual(frame.minY, 92) }
        }
        let ordinary = CGRect(x: 500, y: 400, width: 500, height: 300)
        let below = CaptureSelectionView.toolbarFrame(selection: ordinary, safeBounds: safe, size: size)
        XCTAssertEqual(below.maxY, ordinary.minY - 10)
        let low = CGRect(x: 500, y: 90, width: 500, height: 100)
        let above = CaptureSelectionView.toolbarFrame(selection: low, safeBounds: safe, size: size)
        XCTAssertEqual(above.minY, low.maxY + 10)
    }

    @MainActor func testScrollSelectionRejectsSmallAreaWithoutLosingSelection() async throws {
        let view = CaptureSelectionView(image: try image(), size: CGSize(width: 320, height: 240), windowRects: [])
        view.isScrollingMode = true
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, 10, 10))
        view.mouseDragged(with: try event(.leftMouseDragged, 49, 89))
        XCTAssertFalse(view.canConfirm)
        XCTAssertNotNil(view.selectedRect)
        view.mouseDragged(with: try event(.leftMouseDragged, 50, 90))
        XCTAssertTrue(view.canConfirm)
        view.mouseUp(with: try event(.leftMouseUp, 50, 90))
        let before = try XCTUnwrap(view.selectedRect)
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.keyDown(with: right)
        XCTAssertEqual(try XCTUnwrap(view.selectedRect).minX - before.minX, 0.5, accuracy: 0.001)
    }

    @MainActor func testInlineDimensionsRemainEditableAndApplyPixelSizeAndRatio() throws {
        let view = CaptureSelectionView(image: try image(), size: CGSize(width: 320, height: 240),
                                        windowRects: [CGRect(x: 20, y: 20, width: 100, height: 100)])
        view.isWindowMode = true
        view.updateWindowSelection(at: CGPoint(x: 40, y: 40))
        view.isWindowMode = false
        view.layoutSubtreeIfNeeded()
        let toolbar = try XCTUnwrap(view.subviews.first)
        XCTAssertEqual(toolbar.frame.height, 40)
        let ratioControl = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == L("选区比例") })
        ratioControl.performClick(nil)
        XCTAssertTrue(view.precisionControlsVisible)
        XCTAssertTrue(view.dismissPrecisionControls())
        XCTAssertFalse(view.dismissPrecisionControls())
        XCTAssertTrue(view.canConfirm)
        let fields = view.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        let width = try XCTUnwrap(fields.first { $0.accessibilityLabel() == L("宽度（像素）") })
        let height = try XCTUnwrap(fields.first { $0.accessibilityLabel() == L("高度（像素）") })
        XCTAssertTrue(width.isEditable && height.isEditable)
        width.integerValue = 180; height.integerValue = 120
        width.sendAction(width.action, to: width.target)
        XCTAssertEqual(view.selectedImage()?.width, 180)
        XCTAssertEqual(view.selectedImage()?.height, 120)
        let ratio = try XCTUnwrap(view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.title == "1:1" })
        XCTAssertTrue(ratio.sendAction(ratio.action, to: ratio.target))
        XCTAssertEqual(view.selectedImage()?.width, 180)
        XCTAssertEqual(view.selectedImage()?.height, 180)
    }

    func testExportUpdatesTheChosenFile() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("chosen.png")
        try ImageExporter.save(image(width: 20, height: 30), to: url)
        try ImageExporter.save(image(width: 40, height: 50), to: url)
        let saved = try ImageExporter.read(url)
        XCTAssertEqual(saved.width, 40)
        XCTAssertEqual(saved.height, 50)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["chosen.png"])
    }

    func testAutomaticSaveCreatesFolderAndPreservesEachCapture() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/export-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try ImageExporter.saveAutomatically(image(width: 20, height: 30), in: folder)
        let second = try ImageExporter.saveAutomatically(image(width: 40, height: 50), in: folder)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try ImageExporter.read(first).width, 20)
        XCTAssertEqual(try ImageExporter.read(second).width, 40)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }
}
