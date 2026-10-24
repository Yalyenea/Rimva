import AppKit
import Combine
import RimvaCore

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, text, number, redact, crop
    var id: String { rawValue }
    var title: String { switch self { case .select: return L("选择"); case .arrow: return L("箭头"); case .rectangle: return L("矩形"); case .text: return L("文字"); case .number: return L("序号"); case .redact: return L("遮挡"); case .crop: return L("裁剪") } }
    var symbol: String { switch self { case .select: return "cursorarrow"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .text: return "textformat"; case .number: return "1.circle"; case .redact: return "eye.slash.fill"; case .crop: return "crop" } }
    var annotation: AnnotationKind? { AnnotationKind(rawValue: rawValue) }
}

@MainActor
final class EditorSession: ObservableObject {
    private struct Snapshot: Equatable { var state: EditState; var style: BackgroundStyle }
    @Published private(set) var image: CGImage?
    @Published var state = EditState() { didSet { updateHistory() } }
    @Published var style = BackgroundStyle() { didSet { updateHistory() } }
    @Published var tool: EditorTool = .select
    @Published var selectedID: UUID?
    @Published var pendingCrop: CGRect?
    @Published var colorHex = "#F04444"
    @Published var lineWidth: Double = 6
    @Published var fontSize: Double = 32
    @Published var toast: String?
    // nil fits the window; a value is displayed pixels divided by source pixels.
    @Published var zoom: CGFloat?
    @Published var displayedZoom: CGFloat = 1
    @Published private(set) var savedURL: URL?
    @Published private(set) var clipboardIsStale = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var past: [Snapshot] = []
    private var future: [Snapshot] = []
    private var toastTask: Task<Void, Never>?
    private var savedSnapshot: Snapshot?
    private var copiedSnapshot: Snapshot?
    private var savedBackgroundPath: String?
    private var copiedBackgroundPath: String?
    private var interaction: Snapshot?
    var finishEditing: (() -> Void)?

    private var snapshot: Snapshot { Snapshot(state: state, style: style) }
    private var renderedBackgroundPath: String? {
        style.enabled && style.source == .image ? style.imagePath(for: Preferences.shared.renderAppearance) : nil
    }
    var hasUnsavedChanges: Bool { image != nil && (snapshot != savedSnapshot || renderedBackgroundPath != savedBackgroundPath) }

    var selected: Annotation? { state.annotations.first { $0.id == selectedID } }
    var outputSize: CGSize { guard let image else { return .zero }; return ImageRenderer.outputSize(image: image, state: state, style: style) }

    func load(_ image: CGImage) {
        self.image = image
        style = Preferences.shared.defaultStyle
        state = EditState()
        tool = .select
        selectedID = nil
        pendingCrop = nil
        zoom = nil
        savedURL = nil; savedSnapshot = nil; copiedSnapshot = nil; clipboardIsStale = false
        savedBackgroundPath = nil; copiedBackgroundPath = nil
        toastTask?.cancel(); toast = nil
        interaction = nil
        past.removeAll(); future.removeAll(); updateHistory()
    }

    func releaseImage() {
        image = nil; state = EditState(); selectedID = nil; pendingCrop = nil
        savedURL = nil; savedSnapshot = nil; copiedSnapshot = nil; clipboardIsStale = false; interaction = nil
        savedBackgroundPath = nil; copiedBackgroundPath = nil
        toastTask?.cancel(); toast = nil
        past.removeAll(); future.removeAll(); updateHistory()
    }

    func checkpoint() {
        endInteraction()
        past.append(snapshot)
        // History stores vector edits and style only, never copies of the source.
        if past.count > 60 { past.removeFirst() }
        future.removeAll(); updateHistory()
    }
    // A click, an empty text field, or a discarded tiny shape must not create an undo step.
    func beginInteraction() { if interaction == nil { interaction = snapshot } }
    func endInteraction() {
        guard let initial = interaction else { return }
        interaction = nil
        guard initial != snapshot else { return }
        past.append(initial)
        if past.count > 60 { past.removeFirst() }
        future.removeAll(); updateHistory()
    }
    func markSaved(to url: URL) { savedSnapshot = snapshot; savedBackgroundPath = renderedBackgroundPath; savedURL = url }
    func markCopied() { copiedSnapshot = snapshot; copiedBackgroundPath = renderedBackgroundPath; clipboardIsStale = false }
    func refreshClipboardStatus() {
        let stale = copiedSnapshot.map { $0 != snapshot || copiedBackgroundPath != renderedBackgroundPath } ?? false
        if clipboardIsStale != stale { clipboardIsStale = stale }
    }
    private func updateHistory() {
        let undo = !past.isEmpty || interaction.map { $0 != snapshot } == true
        if canUndo != undo { canUndo = undo }
        if canRedo != !future.isEmpty { canRedo = !future.isEmpty }
    }
    func undo() { finishEditing?(); endInteraction(); guard let value = past.popLast() else { return }; future.append(snapshot); state = value.state; style = value.style; selectedID = nil; updateHistory() }
    func redo() { finishEditing?(); endInteraction(); guard let value = future.popLast() else { return }; past.append(snapshot); state = value.state; style = value.style; selectedID = nil; updateHistory() }
    func changeStyle(_ update: (inout BackgroundStyle) -> Void) {
        var next = style; update(&next)
        guard next != style else { return }
        checkpoint(); style = next
    }
    func updateSelected(_ update: (inout Annotation) -> Void) {
        finishEditing?()
        guard let index = state.annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        var next = state.annotations[index]; update(&next)
        guard next != state.annotations[index] else { return }
        checkpoint(); state.annotations[index] = next
    }
    func deleteSelected() {
        finishEditing?()
        guard let selectedID else { return }
        checkpoint(); state.annotations.removeAll { $0.id == selectedID }; self.selectedID = nil
    }
    func selectTool(_ value: EditorTool) {
        finishEditing?()
        tool = value
        if value != .select { selectedID = nil }
        if value == .crop, let image { pendingCrop = state.crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height) }
        else { pendingCrop = nil }
    }
    func applyCrop() {
        guard let pendingCrop, pendingCrop.width >= 2, pendingCrop.height >= 2 else { return }
        if pendingCrop.integral == state.crop { self.pendingCrop = nil; tool = .select; return }
        checkpoint(); state.crop = pendingCrop.integral; self.pendingCrop = nil; tool = .select
    }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { try? await Task.sleep(for: .seconds(2.4)); guard !Task.isCancelled else { return }; toast = nil }
    }
}
