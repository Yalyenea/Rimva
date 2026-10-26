import AppKit
import Carbon
import RimvaCore
import SwiftUI
import XCTest
@testable import Rimva

final class UIPreviewTests: XCTestCase {
    @MainActor func testCaptureHistoryPreviews() async throws {
        guard let path = ProcessInfo.processInfo.environment["RIMVA_UI_PREVIEW_DIR"] else {
            throw XCTSkip("Run with RIMVA_UI_PREVIEW_DIR to generate capture history previews.")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let history = CaptureHistory(directory: output.appendingPathComponent("captures", isDirectory: true))
        let sample = try XCTUnwrap(SampleImage.make())
        for index in 0..<6 {
            let source = index.isMultiple(of: 2) ? sample
                : try XCTUnwrap(sample.cropping(to: CGRect(x: 0, y: 0, width: sample.width / 2, height: sample.height)))
            history.record(source)
        }
        await history.flush()
        let controller = AppController(hotKey: HotKey(registersShortcuts: false), history: history)
        controller.session.load(sample)
        controller.session.historyShown = true
        let preferences = Preferences.shared
        let original = (preferences.theme, preferences.language, preferences.appearance)
        defer { preferences.theme = original.0; preferences.language = original.1; preferences.appearance = original.2 }
        for theme in AppTheme.allCases {
            preferences.theme = theme
            for (code, language) in [("en", AppLanguage.english), ("zh", .chinese)] {
                preferences.language = language
                for appearance in [AppAppearance.light, .dark] {
                    preferences.appearance = appearance
                    let view = EditorView(session: controller.session, controller: controller)
                    try await snapshot(AnyView(view), size: CGSize(width: 1008, height: 650),
                                       to: output.appendingPathComponent("history-\(theme.rawValue)-\(code)-\(appearance.rawValue).png"))
                }
            }
        }
        try await snapshot(AnyView(EditorView(session: controller.session, controller: controller)),
                           size: CGSize(width: 800, height: 520), to: output.appendingPathComponent("history-compact.png"))
    }

    @MainActor func testCaptureActionPreviews() throws {
        guard let path = ProcessInfo.processInfo.environment["RIMVA_UI_PREVIEW_DIR"] else {
            throw XCTSkip("Run with RIMVA_UI_PREVIEW_DIR to generate capture controls.")
        }
        _ = NSApplication.shared
        let preferences = Preferences.shared
        let original = (preferences.theme, preferences.language, preferences.appearance)
        defer {
            preferences.theme = original.0; preferences.language = original.1; preferences.appearance = original.2
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for theme in AppTheme.allCases {
            preferences.theme = theme
            for (code, language) in [("en", AppLanguage.english), ("zh", .chinese)] {
                preferences.language = language
                for appearance in [AppAppearance.light, .dark] {
                    preferences.appearance = appearance
                    let feedback = CaptureFeedback()
                    for copied in [true, false] {
                        feedback.show(copied: copied, edit: {})
                        let title = copied ? L("已复制") : L("已保存")
                        let feedbackView = try XCTUnwrap(NSApp.windows.first { $0.title == title && $0.isVisible }?.contentView)
                        let kind = copied ? "copied" : "saved"
                        try saveView(feedbackView, to: output.appendingPathComponent("\(kind)-\(theme.rawValue)-\(code)-\(appearance.rawValue).png"))
                        feedback.close()
                    }
                    let launcher = CaptureLauncher()
                    try launcher.show(on: NSScreen.main, openSettings: {}, openEditor: {}) { _ in }
                    let launcherView = try XCTUnwrap(NSApp.windows.first { $0.title == L("截图入口") && $0.isVisible }?.contentView)
                    try saveView(launcherView, to: output.appendingPathComponent("launcher-\(theme.rawValue)-\(code)-\(appearance.rawValue).png"))
                    launcher.close()
                    let bounds = NSRect(x: 0, y: 0, width: 900, height: 600)
                    let view = CaptureSelectionView(image: try XCTUnwrap(SampleImage.make()), size: bounds.size, windowRects: [bounds])
                    view.toolbarSafeBounds = NSRect(x: 0, y: 60, width: 900, height: 502)
                    view.isWindowMode = true
                    view.updateWindowSelection(at: NSPoint(x: 450, y: 300))
                    view.layoutSubtreeIfNeeded()
                    let toolbar = try XCTUnwrap(view.subviews.first)
                    try saveView(toolbar, to: output.appendingPathComponent("capture-\(theme.rawValue)-\(code)-\(appearance.rawValue).png"))
                    // Also render the full region toolbar; the window variant has no precision controls.
                    view.isWindowMode = false
                    view.needsLayout = true
                    view.layoutSubtreeIfNeeded()
                    try saveView(toolbar, to: output.appendingPathComponent("capture-region-\(theme.rawValue)-\(code)-\(appearance.rawValue).png"))
                }
            }
        }
    }

    @MainActor func testRenderPreviews() async throws {
        guard let path = ProcessInfo.processInfo.environment["RIMVA_UI_PREVIEW_DIR"] else {
            throw XCTSkip("Run just preview to generate UI images.")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let assets = output.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let day = assets.appendingPathComponent("Day.png")
        let night = assets.appendingPathComponent("Night.png")
        try ImageExporter.save(background(.dawn), to: day)
        try ImageExporter.save(background(.moon), to: night)
        let sample = try XCTUnwrap(SampleImage.make())
        let style = BackgroundStyle(preset: .irisAbstract, padding: 32, radius: 12)

        // A volatile domain in the XCTest process gives singletons fixed fixtures.
        // The running application's preferences and current document are never opened.
        guard Bundle.main.bundleIdentifier != "com.yfff.Rimva" else {
            XCTFail("UI previews must run in the test process.")
            return
        }
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain([
            "defaultStyle": try JSONEncoder().encode(style), "theme": "rosePine",
            "appearance": "light", "appLanguage": "en", "saveFolder": "/Pictures/Screenshots",
            "automaticSave": false, "automaticCopy": false, "includesCursor": false,
            "backgroundImagePaths": [day.path, night.path], "backgroundFolderPaths": [String](),
            "captureShortcut": Data(), "captureShortcut.window": Data(),
            "captureShortcut.fullScreen": Data(), "captureShortcut.scrolling": Data(),
            "captureShortcut.launcher": try JSONEncoder().encode(KeyCombination(
                keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥S")),
            "captureShortcut.launcher.initialized": true
        ], forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }

        let preferences = Preferences.shared
        let hotKey = HotKey(registersShortcuts: false)
        let history = CaptureHistory(directory: output.appendingPathComponent("editor-captures", isDirectory: true))
        let controller = AppController(hotKey: hotKey, history: history)
        controller.session.load(sample)
        let emptyController = AppController(hotKey: hotKey, history: history)
        let requested = ProcessInfo.processInfo.environment["RIMVA_UI_PREVIEW_THEME"] ?? "rosePine"
        let themes: [AppTheme]
        if requested == "all" { themes = AppTheme.allCases }
        else { themes = [try XCTUnwrap(AppTheme(rawValue: requested), "Unknown theme: \(requested)")] }

        if ProcessInfo.processInfo.environment["RIMVA_UI_PREVIEW_LIVE"] == "1" {
            preferences.theme = try XCTUnwrap(themes.first)
            preferences.language = .english
            preferences.appearance = .light
            let fixture = assets.appendingPathComponent("Sample.png")
            try ImageExporter.save(sample, to: fixture)
            controller.session.markSaved(to: fixture)
            try await livePreview(controller, output: output)
            return
        }

        // Let the background library decode the generated fixtures before drawing the grid.
        for _ in 0..<100 {
            if BackgroundLibrary.shared.images.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(BackgroundLibrary.shared.images.count, 2)
        var filenames: [String] = []
        for theme in themes {
            preferences.theme = theme
            for (code, language) in [("en", AppLanguage.english), ("zh", .chinese)] {
                preferences.language = language
                for appearance in [AppAppearance.light, .dark] {
                    preferences.appearance = appearance
                    let suffix = "\(theme.rawValue)-\(code)-\(appearance.rawValue)"
                    for (name, size, view) in [
                        ("settings", CGSize(width: 940, height: 760), AnyView(SettingsView(preferences: preferences, hotKey: hotKey))),
                        ("editor", CGSize(width: 1008, height: 650), AnyView(EditorView(session: controller.session, controller: controller))),
                        ("background", CGSize(width: 344, height: 560), AnyView(BackgroundPopover(session: controller.session))),
                        ("empty", CGSize(width: 1008, height: 650), AnyView(EditorView(session: emptyController.session, controller: emptyController)))
                    ] {
                        let filename = "\(name)-\(suffix).png"
                        try await snapshot(view, size: size, to: output.appendingPathComponent(filename))
                        filenames.append(filename)
                    }
                }
            }
            preferences.language = .english
            preferences.appearance = .light
            let filename = "settings-\(theme.rawValue)-en-compact.png"
            try await snapshot(AnyView(SettingsView(preferences: preferences, hotKey: hotKey)),
                               size: CGSize(width: 680, height: 1440), to: output.appendingPathComponent(filename))
            filenames.append(filename)
        }
        try filenames.joined(separator: "\n").write(to: output.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        print("UI previews: \(output.path) (\(filenames.count) images)")
    }

    @MainActor private func livePreview(_ controller: AppController, output: URL) async throws {
        NSApp.setActivationPolicy(.accessory)
        let size = CGSize(width: 1008, height: 650)
        let window = EditorWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.session = controller.session
        window.title = "Rimva UI Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let probe = HelpProbe()
        let root = EditorView(session: controller.session, controller: controller)
            .overlayPreferenceValue(IconHelpKey.self) { help in
                probe.text = help?.text
                return Color.clear.allowsHitTesting(false)
            }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(CGRect(origin: .zero, size: size), display: false)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let sample = try XCTUnwrap(controller.session.image)
        let savedURL = try XCTUnwrap(controller.session.savedURL)
        // Local shortcuts only switch this fixture; they never register system-wide keys.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            let key = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated {
                switch key {
                case "0": controller.session.releaseImage(); return true
                case "1": controller.session.load(sample); controller.session.markSaved(to: savedURL); return true
                default: return false
                }
            }
            return handled ? nil : event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            window.close()
        }
        if ProcessInfo.processInfo.environment["RIMVA_UI_PREVIEW_CHECK"] == "1" {
            try await runEvents(for: .milliseconds(150))
            try click(L("背景外观"), in: host, window: window)
            try await runEvents(for: .milliseconds(250))
            XCTAssertTrue(controller.session.backgroundShown, "Clicking Background must open the popover")
            let popover = try XCTUnwrap(NSApp.windows.first { $0 !== window && $0.isVisible }, "Background popover did not open")
            XCTAssertGreaterThan(popover.frame.width, 300)
            XCTAssertEqual(try XCTUnwrap(descendants(host).compactMap { $0 as? EditorCanvas }.first).bounds.width, size.width, accuracy: 1)
            try saveView(try XCTUnwrap(popover.contentView?.superview), to: output.appendingPathComponent("popover-live.png"))
            controller.session.backgroundShown = false
            try await runEvents(for: .milliseconds(150))
            XCTAssertFalse(popover.isVisible)

            try click(EditorTool.arrow.title, in: host, window: window)
            try await runEvents(for: .milliseconds(100))
            XCTAssertEqual(controller.session.tool, .arrow)
            try click(EditorTool.select.title, in: host, window: window)
            try await runEvents(for: .milliseconds(100))
            XCTAssertEqual(controller.session.tool, .select)

            controller.session.releaseImage()
            try await runEvents(for: .milliseconds(150))
            let hover = try XCTUnwrap(descendants(host).compactMap { $0 as? IconHoverView }
                .first { $0.accessibilityIdentifier() == L("背景外观") })
            let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            hover.mouseEntered(with: enter)
            try await runEvents(for: .milliseconds(500))
            XCTAssertEqual(probe.text, L("%@（%@）", L("背景外观"), "B"))
            try saveView(host, to: output.appendingPathComponent("empty-hover-live.png"))
            return
        }
        // This fixture window has no document-close delegate, so editing and closing
        // it never asks to save or closes the user's running Rimva instance.
        while window.isVisible { try await runEvents(for: .milliseconds(150)) }
    }

    @MainActor private final class HelpProbe { var text: String? }

    @MainActor private func runEvents(for duration: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        repeat {
            // XCTest services the run loop without NSApplication.run(), so the
            // interactive fixture must also dispatch AppKit's queued input events.
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
    }

    @MainActor private func click(_ title: String, in host: NSView, window: NSWindow) throws {
        let target = try XCTUnwrap(descendants(host).compactMap { $0 as? IconHoverView }
            .first { $0.accessibilityIdentifier() == title })
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.postEvent(event, atStart: false)
        }
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor private func saveView(_ view: NSView, to url: URL) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }

    private func background(_ preset: BackgroundPreset) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try ImageRenderer.render(image: XCTUnwrap(context.makeImage()), state: EditState(),
                                        style: BackgroundStyle(preset: preset, padding: 0, rounded: false, shadow: .off))
    }

    @MainActor private func snapshot(_ view: AnyView, size: CGSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = Preferences.shared.appearance.native
        window.contentView = host
        window.setFrame(CGRect(x: -10000, y: -10000, width: size.width, height: size.height), display: false)
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // SwiftUI schedules representable updates and image tasks after layout.
        try await Task.sleep(for: .milliseconds(100))
        Preferences.shared.permissionGranted = true
        Preferences.shared.loginStatus = .notRegistered
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
