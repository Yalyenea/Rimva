import AppKit
import Carbon
import Combine
import RimvaCore
import SwiftUI

private let shortcutSignature: OSType = 0x52494D56

struct KeyCombination: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
}

enum ShortcutAction: UInt32, CaseIterable, Identifiable {
    case area = 1, window = 2, fullScreen = 3
    case launcher = 4, scrolling = 5

    // Presentation order is independent of the persistent Carbon action IDs.
    static var allCases: [ShortcutAction] { [.launcher, .area, .window, .fullScreen, .scrolling] }

    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .area: return L("区域截图")
        case .window: return L("窗口截图")
        case .fullScreen: return L("全屏截图")
        case .launcher: return L("截图入口")
        case .scrolling: return L("长截屏")
        }
    }

    fileprivate var storageKey: String {
        switch self {
        // Preserve the original preference so existing shortcuts migrate in place.
        case .area: return "captureShortcut"
        case .window: return "captureShortcut.window"
        case .fullScreen: return "captureShortcut.fullScreen"
        case .launcher: return "captureShortcut.launcher"
        case .scrolling: return "captureShortcut.scrolling"
        }
    }
}

@MainActor
final class HotKey: ObservableObject {
    @Published private(set) var combinations: [ShortcutAction: KeyCombination] = [:]
    @Published var error: String?
    var onTrigger: ((ShortcutAction) -> Void)?
    fileprivate var recordingAction: ShortcutAction?
    fileprivate var recordingHandler: ((KeyCombination) -> Void)?
    private var references: [ShortcutAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var languageObserver: AnyCancellable?
    private var errorKey: String?
    private let registersShortcuts: Bool

    init(registersShortcuts: Bool = true) {
        self.registersShortcuts = registersShortcuts
        languageObserver = NotificationCenter.default.publisher(for: .rimvaLanguageChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                self.error = self.errorKey.map { L($0) }
            }
        // Preview processes display the same bindings without competing for the live app's keys.
        if registersShortcuts {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let event, let data else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard result == noErr, id.signature == shortcutSignature,
                      let action = ShortcutAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue()
                // Carbon dispatches application events on the main thread.
                MainActor.assumeIsolated {
                    if hotKey.recordingAction != nil {
                        // Our registered combinations arrive as Carbon events while recording.
                        if let combination = hotKey.combinations[action] { hotKey.recordingHandler?(combination) }
                    } else { hotKey.onTrigger?(action) }
                }
                return noErr
            }, 1, &type, pointer, &handler)
        }
        var restoredError: String?
        for action in ShortcutAction.allCases {
            if let data = UserDefaults.standard.data(forKey: action.storageKey),
               let key = try? JSONDecoder().decode(KeyCombination.self, from: data) {
                set(key, for: action)
                if let errorKey { restoredError = errorKey }
            }
        }
        let initializationKey = "captureShortcut.launcher.initialized"
        if !UserDefaults.standard.bool(forKey: initializationKey) {
            // Remember first use even when registration fails or the user later clears it.
            UserDefaults.standard.set(true, forKey: initializationKey)
            if UserDefaults.standard.data(forKey: ShortcutAction.launcher.storageKey) == nil {
                set(KeyCombination(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥S"), for: .launcher)
                if let errorKey { restoredError = errorKey }
            }
        }
        if let restoredError { reportError(restoredError) }
    }

    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func combination(for action: ShortcutAction) -> KeyCombination? { combinations[action] }

    func set(_ next: KeyCombination?, for action: ShortcutAction) {
        if next == combinations[action] { reportError(nil); return }
        var newReference: EventHotKeyRef?
        if let next {
            let reserved = next.modifiers == UInt32(cmdKey | shiftKey)
                && [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5)].contains(next.keyCode)
            guard !reserved else { reportError("该组合键用于系统截图，请换一个。"); return }
            let duplicate = combinations.contains { other, combination in
                other != action && combination.keyCode == next.keyCode && combination.modifiers == next.modifiers
            }
            guard !duplicate else { reportError("该组合键已用于其他截图操作，请换一个。"); return }
            // Keep the working shortcut registered until its replacement succeeds.
            if registersShortcuts {
                let id = EventHotKeyID(signature: shortcutSignature, id: action.rawValue)
                // Exclusive registration reports an existing owner instead of sharing its keystrokes.
                let result = RegisterEventHotKey(next.keyCode, next.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &newReference)
                guard result == noErr else { reportError("快捷键已被占用，请换一个。"); return }
            }
        }
        if let reference = references[action] { UnregisterEventHotKey(reference) }
        references[action] = newReference
        combinations[action] = next
        if let next, let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: action.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: action.storageKey)
        }
        reportError(nil)
    }

    fileprivate func reportError(_ key: String?) {
        errorKey = key
        error = key.map { L($0) }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var hotKey: HotKey
    var action: ShortcutAction
    var tint: NSColor? = nil

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.hotKey = hotKey
        view.shortcutAction = action
        view.contentTintColor = tint
        view.refreshLabels()
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.hotKey = hotKey
        view.shortcutAction = action
        view.contentTintColor = tint
        view.refreshLabels()
    }
}

final class RecorderButton: NSButton {
    weak var hotKey: HotKey?
    var shortcutAction: ShortcutAction = .area
    private var recording = false
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .inline
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        target = self
        action = #selector(beginRecording)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLabels), name: .rimvaLanguageChanged, object: nil)
        refreshLabels()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func refreshLabels() {
        let combination = hotKey?.combination(for: shortcutAction)
        title = recording ? "…" : combination?.label ?? L("录入")
        font = combination != nil && !recording
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        setAccessibilityLabel(shortcutAction.title)
        setAccessibilityValue(recording ? L("按下组合键…") : title)
        toolTip = recording ? L("按下组合键…") : L("点击录入快捷键")
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Preferences.shared.palette
        let labelFont = font ?? NSFont.systemFont(ofSize: 12)
        let labelSize = (title as NSString).size(withAttributes: [.font: labelFont])
        // The hit area stays generous while the keycap hugs its label.
        let width = min(bounds.width - 1, max(44, ceil(labelSize.width) + 18))
        let rect = NSRect(x: bounds.maxX - width - 0.5, y: bounds.midY - 12, width: width, height: 24)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (recording || isHighlighted ? palette.selection : palette.elevated).setFill()
        shape.fill()
        let focused = window?.firstResponder === self
        (recording || focused ? palette.accent : palette.separator).setStroke()
        shape.lineWidth = recording || focused ? 1 : 0.5
        shape.stroke()
        let labelRect = NSRect(x: rect.midX - labelSize.width / 2, y: rect.midY - labelSize.height / 2,
                               width: labelSize.width, height: labelSize.height)
        (title as NSString).draw(in: labelRect, withAttributes: [.font: labelFont, .foregroundColor: recording ? palette.accentText : contentTintColor ?? palette.text])
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    @objc private func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        recording = true
        hotKey?.recordingAction = shortcutAction
        hotKey?.recordingHandler = { [weak self] combination in self?.record(combination) }
        hotKey?.reportError(nil)
        refreshLabels()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { stopRecording() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func stopRecording() {
        recording = false
        if hotKey?.recordingAction == shortcutAction {
            hotKey?.recordingAction = nil
            hotKey?.recordingHandler = nil
        }
        refreshLabels()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            if event.keyCode == 49 || event.keyCode == 36 { beginRecording() }
            else { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            hotKey?.set(nil, for: shortcutAction)
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            hotKey?.reportError("请搭配 ⌘、⌃ 或 ⌥ 录入。")
            return
        }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += keyLabel(for: event)
        record(KeyCombination(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label))
    }

    private func record(_ combination: KeyCombination) {
        hotKey?.set(combination, for: shortcutAction)
        if hotKey?.error == nil { window?.makeFirstResponder(nil) }
    }

    private func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36, 76: return "↩"
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
               scalar.value >= 0xF704 && scalar.value <= 0xF726 {
                return "F\(scalar.value - 0xF704 + 1)"
            }
            return event.charactersIgnoringModifiers?.uppercased() ?? ""
        }
    }
}
