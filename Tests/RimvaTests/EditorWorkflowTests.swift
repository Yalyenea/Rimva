import AppKit
import Carbon
import ScreenCaptureKit
import XCTest
import RimvaCore
@testable import Rimva

final class EditorWorkflowTests: XCTestCase {
    private var originalStyle: BackgroundStyle?
    private var originalSaveFolder: URL?
    private var saveFolderFixture: URL?
    private var historyFixtures: [(URL, CaptureHistory)] = []

    @MainActor override func setUp() async throws {
        // Command-line XCTest has no application host, but Preferences uses AppKit's NSApp.
        _ = NSApplication.shared
        originalStyle = Preferences.shared.defaultStyle
        originalSaveFolder = Preferences.shared.saveFolder
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/workflow-saved-\(UUID().uuidString)")
        saveFolderFixture = folder
        Preferences.shared.saveFolder = folder
    }

    @MainActor override func tearDown() async throws {
        for (url, history) in historyFixtures {
            await history.flush()
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        historyFixtures.removeAll()
        if let folder = saveFolderFixture, FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        if let originalSaveFolder { Preferences.shared.saveFolder = originalSaveFolder }
        if let originalStyle { Preferences.shared.defaultStyle = originalStyle }
    }

    @MainActor private func makeHistory() -> CaptureHistory {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/workflow-history-\(UUID().uuidString)")
        let history = CaptureHistory(directory: url)
        historyFixtures.append((url, history))
        return history
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
        let controller = AppController(hotKey: HotKey(registersShortcuts: false), history: makeHistory())
        controller.showEditor()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Rimva" && $0.isVisible })
        defer { window.close() }
        for width in [640, 800] {
            let captured = try image(width: width)
            controller.finishCapture(captured)
            let saved = try XCTUnwrap(preferences.lastSavedURL)
            XCTAssertNotNil(try ImageExporter.read(saved))
            XCTAssertNil(controller.session.image)
            XCTAssertFalse(controller.session.hasUnsavedChanges)
            XCTAssertFalse(window.isVisible)
            controller.showEditor()
            XCTAssertTrue(controller.session.image === captured, "Reopening must restore the latest original, not its rendered export")
            XCTAssertEqual(controller.session.image?.width, width)
            controller.session.releaseImage()
            window.orderOut(nil)
        }
        controller.showCaptureLauncher()
        XCTAssertEqual(try sendLauncherShortcut(UInt32(kVK_ANSI_6)), noErr)
        XCTAssertNil(controller.session.image, "Settings must open without reopening the last capture")
        let settings = try XCTUnwrap(NSApp.windows.first { $0.title == L("Rimva 设置") && $0.isVisible })
        settings.close()
        controller.finishCapture(try image(), opensEditor: true)
        XCTAssertNotNil(controller.session.image)
        XCTAssertTrue(window.isVisible)
        controller.session.state.crop = CGRect(x: 10, y: 10, width: 100, height: 80)
        controller.showEditor()
        XCTAssertEqual(controller.session.state.crop, CGRect(x: 10, y: 10, width: 100, height: 80),
                       "Opening an existing editor must keep the current edits")
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

    @MainActor func testHistoryOpensInTheSameEditorAndCopyKeepsTheCurrentDocument() async throws {
        let history = makeHistory()
        let first = history.record(try image(width: 120, height: 80))
        let second = history.record(try image(width: 240, height: 160))
        await history.flush()
        let controller = AppController(hotKey: HotKey(registersShortcuts: false), history: history)
        controller.showEditor()
        let editor = try XCTUnwrap(NSApp.windows.first { $0.title == "Rimva" && $0.isVisible })
        defer { editor.close() }
        controller.session.historyShown = true
        controller.openCapture(first)
        for _ in 0..<100 {
            if controller.session.captureID == first.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.session.captureID, first.id)
        XCTAssertEqual(controller.session.image?.width, 120)
        XCTAssertFalse(controller.session.historyShown)
        XCTAssertFalse(controller.session.hasEdits)

        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = board.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        defer { board.clearContents(); if !saved.isEmpty { board.writeObjects(saved) } }
        board.clearContents()
        controller.session.historyShown = true
        controller.copyCapture(second)
        for _ in 0..<100 {
            if board.data(forType: .png) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let data = try XCTUnwrap(board.data(forType: .png))
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 240)
        XCTAssertEqual(controller.session.captureID, first.id)
        XCTAssertTrue(controller.session.historyShown)
        controller.copyCapture(second)
        controller.copyImage()
        let newerCopy = try XCTUnwrap(board.data(forType: .png))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(board.data(forType: .png), newerCopy, "A pending history copy must not replace a newer editor copy")
        controller.openCapture(second)
        for _ in 0..<100 {
            if controller.session.captureID == second.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.session.captureID, second.id)
        XCTAssertEqual(controller.session.image?.width, 240)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "Rimva" && $0.isVisible }.count, 1)
        XCTAssertTrue(NSApp.windows.first { $0.title == "Rimva" && $0.isVisible } === editor)
        controller.setHistoryShown(true)
        controller.openCapture(first)
        controller.setHistoryShown(false)
        controller.setHistoryShown(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.session.captureID, second.id, "Leaving history cancels a pending image even if history is reopened")
        controller.session.state.crop = CGRect(x: 0, y: 0, width: 30, height: 30)
        XCTAssertTrue(controller.session.hasEdits)
        controller.session.historyShown = true
        controller.openCapture(second)
        XCTAssertEqual(controller.session.state.crop?.width, 30, "Opening the current history item keeps its edits")
    }

    @MainActor func testAutomaticCopyKeepsFeedbackVisibleAfterQuickCaptureReleasesTheImage() throws {
        let preferences = Preferences.shared
        let originalCopy = preferences.automaticCopy
        let originalSave = preferences.automaticSave
        let originalOpen = preferences.opensEditorAfterCapture
        let pasteboard = NSPasteboard.general
        let items: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        } ?? []
        defer {
            preferences.automaticCopy = originalCopy
            preferences.automaticSave = originalSave
            preferences.opensEditorAfterCapture = originalOpen
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        preferences.automaticCopy = true
        preferences.automaticSave = false
        preferences.opensEditorAfterCapture = false
        let controller = AppController(hotKey: HotKey(registersShortcuts: false), history: makeHistory())
        let captured = try image(width: 411, height: 291)
        controller.finishCapture(captured)
        XCTAssertNil(controller.session.image)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        let feedback = try XCTUnwrap(NSApp.windows.first { $0.title == L("已复制") && $0.isVisible })
        XCTAssertFalse(feedback.ignoresMouseEvents, "The Edit action must accept clicks")
        XCTAssertFalse(feedback.isKeyWindow)
        pasteboard.clearContents()
        pasteboard.setString("New clipboard content", forType: .string)
        controller.showEditor()
        defer { NSApp.windows.first { $0.title == "Rimva" && $0.isVisible }?.close() }
        XCTAssertTrue(controller.session.image === captured, "Reopening must not depend on the clipboard")
        XCTAssertFalse(feedback.isVisible)
    }

    @MainActor func testCaptureLauncherPreservesKeyWindowAndDispatchesScopedShortcuts() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let originalKey = NSApp.keyWindow
        let launcher = CaptureLauncher()
        defer { launcher.close(); window.close() }
        let bindings: [(UInt32, String)] = [
            (18, "region"), (19, "scrolling"), (20, "window"), (21, "fullScreen"), (23, "editor"),
            (83, "region"), (84, "scrolling"), (85, "window"), (86, "fullScreen"), (87, "editor"),
            (36, "region"), (76, "region"), (22, "settings"), (88, "settings")
        ]
        for (key, expected) in bindings {
            let selected = expectation(description: "Launcher key \(key)")
            var actions: [String] = []
            try launcher.show(on: NSScreen.main, openSettings: { actions.append("settings"); selected.fulfill() },
                              openEditor: { actions.append("editor"); selected.fulfill() }) { mode in
                actions.append(String(describing: mode))
                selected.fulfill()
            }
            XCTAssertTrue(launcher.isVisible)
            XCTAssertTrue(NSApp.keyWindow === originalKey, "Showing the launcher must leave keyboard focus alone")
            XCTAssertEqual(try sendLauncherShortcut(key), noErr)
            await fulfillment(of: [selected], timeout: 1)
            XCTAssertEqual(actions, [expected])
            XCTAssertFalse(launcher.isVisible)
            // A released launcher must not respond to queued hotkeys from its previous session.
            _ = try sendLauncherShortcut(key)
            XCTAssertEqual(actions, [expected])
        }
        try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: { XCTFail("Escape must not open the editor") }) { _ in
            XCTFail("Escape must not choose a mode")
        }
        XCTAssertEqual(try sendLauncherShortcut(53), noErr)
        XCTAssertFalse(launcher.isVisible)
    }

    @MainActor func testCaptureLauncherRegistrationFailureReleasesPartialShortcuts() throws {
        var conflict: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x54455354, id: 1)
        XCTAssertEqual(RegisterEventHotKey(19, 0, id, GetEventDispatcherTarget(),
                                           OptionBits(kEventHotKeyExclusive), &conflict), noErr)
        let conflictingKey = try XCTUnwrap(conflict)
        defer { UnregisterEventHotKey(conflictingKey) }
        let launcher = CaptureLauncher()
        defer { launcher.close() }
        XCTAssertThrowsError(try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in })
        XCTAssertFalse(launcher.isVisible)
        // Key 1 registered before the conflict on key 2; failure must release it too.
        var released: EventHotKeyRef?
        XCTAssertEqual(RegisterEventHotKey(18, 0, id, GetEventDispatcherTarget(),
                                           OptionBits(kEventHotKeyExclusive), &released), noErr)
        if let released { UnregisterEventHotKey(released) }
    }

    @MainActor func testCaptureLauncherKeepsTransientPopoverOpenUntilCaptureChoice() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 160),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let anchor = try XCTUnwrap(window.contentView)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        popover.contentViewController = content
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let launcher = CaptureLauncher()
        defer { launcher.close(); popover.close(); window.close() }
        XCTAssertTrue(popover.isShown)
        let selected = expectation(description: "Popover remains available to capture")
        try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in
            XCTAssertTrue(popover.isShown, "The capture must start before transient content is dismissed")
            selected.fulfill()
        }
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(try sendLauncherShortcut(18), noErr)
        await fulfillment(of: [selected], timeout: 1)
        XCTAssertTrue(popover.isShown)
    }

    @MainActor func testCaptureLauncherReleasesShortcutsWhenWorkspaceChanges() throws {
        let launcher = CaptureLauncher()
        defer { launcher.close() }
        let workspace = NSWorkspace.shared.notificationCenter
        let otherApplication = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        })
        for application in [NSRunningApplication.current, otherApplication] {
            try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in }
            XCTAssertTrue(launcher.isVisible)
            workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                           userInfo: [NSWorkspace.applicationUserInfoKey: application])
            XCTAssertFalse(launcher.isVisible)
        }
        try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in }
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertFalse(launcher.isVisible)
        try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in }
        launcher.close()
        launcher.close()
        try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in }
        XCTAssertTrue(launcher.isVisible)
    }

    @MainActor func testCaptureLauncherReleasesShortcutsBeforeAnotherWindowTakesKeys() throws {
        let launcher = CaptureLauncher()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { launcher.close(); window.close() }
        try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in }
        // XCTest has no foreground application host; deliver AppKit's window transition directly.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(launcher.isVisible, "Editor and file dialogs must receive their normal keys")
        try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in }
        XCTAssertTrue(launcher.isVisible, "Released shortcuts must be available for the next launcher")
    }

    @MainActor private func sendLauncherShortcut(_ key: UInt32) throws -> OSStatus {
        var created: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), 0, &created), noErr)
        let event = try XCTUnwrap(created)
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: 0x52494D4C, id: key)
        XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         MemoryLayout<EventHotKeyID>.size, &id), noErr)
        return SendEventToEventTarget(event, GetEventDispatcherTarget())
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

    @MainActor func testWindowSelectionCapturesClickedTargetImmediately() throws {
        let view = CaptureSelectionView(image: try image(), size: CGSize(width: 320, height: 240),
                                        windowRects: [CGRect(x: 20, y: 20, width: 100, height: 100),
                                                      CGRect(x: 150, y: 20, width: 100, height: 100)])
        view.isWindowMode = true
        var actions: [Bool] = []
        view.onConfirm = { actions.append($0) }
        view.updateWindowSelection(at: CGPoint(x: 180, y: 40))
        XCTAssertEqual(view.selectedRect, CGRect(x: 150, y: 20, width: 100, height: 100))
        XCTAssertEqual(view.selectedWindowIndex, 1)
        XCTAssertTrue(actions.isEmpty, "Hovering only previews the target")
        let toolbar = try XCTUnwrap(view.subviews.first)
        XCTAssertTrue(toolbar.isHidden)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 40, y: 40),
                                                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        XCTAssertEqual(actions, [false], "One click captures without opening the editor explicitly")
        XCTAssertEqual(view.selectedRect, CGRect(x: 20, y: 20, width: 100, height: 100))
        XCTAssertEqual(view.selectedWindowIndex, 0)
        XCTAssertNil(view.selectedImage(), "Window capture must use its native window instead of cropping the desktop")

        let emptyClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 280, y: 200),
                                                         modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: emptyClick)
        XCTAssertEqual(actions, [false], "Clicking outside a window cannot capture the previous hover target")
        XCTAssertNil(view.selectedRect)
        XCTAssertNil(view.selectedWindowIndex)

        view.isWindowMode = false
        XCTAssertFalse(toolbar.isHidden, "Area selection keeps its confirmation controls")
    }

    @MainActor func testLiveWindowSelectionHasNoFrozenImageAndSelectsTheTopmostPopup() throws {
        let popup = CGRect(x: 120, y: 80, width: 140, height: 120)
        let document = CGRect(x: 20, y: 20, width: 280, height: 200)
        let view = CaptureSelectionView(image: nil, size: CGSize(width: 320, height: 240),
                                        windowRects: [popup, document])
        view.isWindowMode = true
        view.updateWindowSelection(at: CGPoint(x: 150, y: 100))
        XCTAssertEqual(view.selectedWindowIndex, 0)
        XCTAssertEqual(view.selectedRect, popup)
        XCTAssertTrue(view.canConfirm)
        XCTAssertNil(view.selectedImage())
        view.updateWindowSelection(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(view.selectedWindowIndex, 1)
        view.clearSelection()
        XCTAssertNil(view.selectedWindowIndex)
        XCTAssertFalse(view.canConfirm)
        let panel = CapturePanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.acceptsSelectionKeys = false
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
    }

    @MainActor func testWindowPanelDispatchesOneClickWithoutTakingKeyboardFocus() throws {
        let view = CaptureSelectionView(image: nil, size: CGSize(width: 320, height: 240),
                                        windowRects: [CGRect(x: 20, y: 20, width: 220, height: 160)])
        view.isWindowMode = true
        let panel = CapturePanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.acceptsSelectionKeys = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.contentView = view
        panel.orderFrontRegardless()
        defer { panel.close() }
        let keyWindow = NSApp.keyWindow
        var captures = 0
        view.onConfirm = { _ in captures += 1 }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 80, y: 80),
                                                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        panel.sendEvent(click)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(view.selectedWindowIndex, 0)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertFalse(panel.isKeyWindow)
    }

    @MainActor func testWindowCandidatesIncludeFloatingAndMenuLayers() {
        let frame = CGRect(x: 100, y: 100, width: 280, height: 180)
        for layer in [0, 3, 8, 20, 24, 25, 101] {
            XCTAssertTrue(CaptureCoordinator.isSelectableWindow(layer: layer, frame: frame, ownerPID: 1))
        }
        XCTAssertFalse(CaptureCoordinator.isSelectableWindow(layer: -1, frame: frame, ownerPID: 1))
        XCTAssertFalse(CaptureCoordinator.isSelectableWindow(layer: 1000, frame: frame, ownerPID: 1))
        XCTAssertFalse(CaptureCoordinator.isSelectableWindow(layer: 3, frame: frame,
                                                             ownerPID: ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(CaptureCoordinator.isSelectableWindow(layer: 3, frame: .zero, ownerPID: 1))
    }

    func testNativeWindowTrimmingPreservesEveryShadowAndBorderPixel() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.withAlphaComponent(1.0 / 255).cgColor)
        context.fill(CGRect(x: 3, y: 4, width: 28, height: 18))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 7, y: 8, width: 20, height: 10))
        let result = try NativeWindowCapture.trimTransparentBorder(try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(result.width, 28)
        XCTAssertEqual(result.height, 18)
        // The faintest native shadow is kept, rather than thresholded or rounded away.
        let bitmap = NSBitmapImageRep(cgImage: result)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1.0 / 255, accuracy: 1.0 / 255)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 10, y: 8)).alphaComponent, 0.99)
    }

    func testNativeWindowTrimmingKeepsAsymmetricAlphaInTheOriginalPixelCoordinates() throws {
        let width = 12, height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let red = (3 * width + 2) * 4
        pixels[red] = 64; pixels[red + 3] = 64
        let blue = (14 * width + 8) * 4
        pixels[blue + 2] = 128; pixels[blue + 3] = 128
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                             | CGBitmapInfo.byteOrder32Big.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let result = try NativeWindowCapture.trimTransparentBorder(image)
        XCTAssertEqual(result.width, 7)
        XCTAssertEqual(result.height, 12)
        let bitmap = NSBitmapImageRep(cgImage: result)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).redComponent, 0.99)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 6, y: 11)).blueComponent, 0.99)
    }

    @MainActor func testNativeWindowCaptureKeepsTransparencyAndReadsTheLiveWindow() async throws {
        guard CaptureCoordinator.permissionGranted else { throw XCTSkip("Screen recording access is required") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else { throw XCTSkip("Native capture needs a display-backed application host") }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 220, height: 140),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        let box = NSBox(frame: NSRect(x: 0, y: 0, width: 220, height: 140))
        box.boxType = .custom
        box.fillColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        window.contentView = box
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        defer { window.close() }
        // Let WindowServer publish the newly created test surface before asking it for pixels.
        try await Task.sleep(for: .milliseconds(100))
        let id = CGWindowID(window.windowNumber)
        let first = try await NativeWindowCapture.image(of: id, includesCursor: false)
        let firstBitmap = NSBitmapImageRep(cgImage: first)
        // ScreenCaptureKit retains the display profile; compare colors in the fixture's sRGB space.
        let red = try XCTUnwrap(firstBitmap.colorAt(x: first.width / 2, y: first.height / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(red.redComponent, 0.8)
        XCTAssertGreaterThan(red.redComponent - red.greenComponent, 0.4)
        XCTAssertGreaterThanOrEqual(first.width, Int(window.frame.width * window.backingScaleFactor))
        XCTAssertLessThan(try XCTUnwrap(firstBitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)

        box.fillColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        box.needsDisplay = true
        window.displayIfNeeded()
        let second = try await NativeWindowCapture.image(of: id, includesCursor: false)
        let bitmap = NSBitmapImageRep(cgImage: second)
        let green = try XCTUnwrap(bitmap.colorAt(x: second.width / 2, y: second.height / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(green.greenComponent, 0.8)
        XCTAssertGreaterThan(green.greenComponent - green.redComponent, 0.25)
        XCTAssertLessThan(green.redComponent, red.redComponent - 0.25,
                          "The second capture must read the changed window, not an earlier screen image")
        XCTAssertGreaterThan(green.greenComponent, red.greenComponent + 0.25)
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
