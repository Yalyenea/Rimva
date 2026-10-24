import AppKit
import XCTest
import RimvaCore
@testable import Rimva

final class EditorWorkflowTests: XCTestCase {
    @MainActor override func setUp() async throws {
        // Command-line XCTest has no application host, but Preferences uses AppKit's NSApp.
        _ = NSApplication.shared
    }

    private func image(width: Int = 640, height: Int = 480) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
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
}
