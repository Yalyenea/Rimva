import AppKit
import Combine
import RimvaCore

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, text, number, redact, crop
    var id: String { rawValue }
    var title: String { switch self { case .select: return L("选择"); case .arrow: return L("箭头"); case .rectangle: return L("矩形"); case .text: return L("文字"); case .number: return L("序号"); case .redact: return L("遮挡"); case .crop: return L("裁剪") } }
    var symbol: String { switch self { case .select: return "cursorarrow"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .text: return "textformat"; case .number: return "list.number"; case .redact: return "rectangle.fill"; case .crop: return "crop" } }
    var annotation: AnnotationKind? { AnnotationKind(rawValue: rawValue) }
}

@MainActor
final class EditorSession: ObservableObject {
    private struct Snapshot { var state: EditState; var style: BackgroundStyle }
    @Published private(set) var image: CGImage?
    @Published var state = EditState()
    @Published var style = BackgroundStyle()
    @Published var tool: EditorTool = .select
    @Published var selectedID: UUID?
    @Published var pendingCrop: CGRect?
    @Published var colorHex = "#F04444"
    @Published var lineWidth: Double = 6
    @Published var fontSize: Double = 32
    @Published var toast: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var past: [Snapshot] = []
    private var future: [Snapshot] = []
    private var toastTask: Task<Void, Never>?

    var selected: Annotation? { state.annotations.first { $0.id == selectedID } }
    var outputSize: CGSize { guard let image else { return .zero }; return ImageRenderer.outputSize(image: image, state: state, style: style) }

    func load(_ image: CGImage) {
        self.image = image
        style = Preferences.shared.defaultStyle
        state = EditState()
        tool = .select
        selectedID = nil
        pendingCrop = nil
        past.removeAll(); future.removeAll(); updateHistory()
    }

    func releaseImage() {
        image = nil; state = EditState(); selectedID = nil; pendingCrop = nil
        past.removeAll(); future.removeAll(); updateHistory()
    }

    func checkpoint() {
        past.append(Snapshot(state: state, style: style))
        // History stores vector edits and style only, never copies of the source.
        if past.count > 60 { past.removeFirst() }
        future.removeAll(); updateHistory()
    }
    private func updateHistory() { canUndo = !past.isEmpty; canRedo = !future.isEmpty }
    func undo() { guard let value = past.popLast() else { return }; future.append(Snapshot(state: state, style: style)); state = value.state; style = value.style; selectedID = nil; updateHistory() }
    func redo() { guard let value = future.popLast() else { return }; past.append(Snapshot(state: state, style: style)); state = value.state; style = value.style; selectedID = nil; updateHistory() }
    func changeStyle(_ update: (inout BackgroundStyle) -> Void) { checkpoint(); update(&style) }
    func updateSelected(_ update: (inout Annotation) -> Void) {
        guard let index = state.annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        checkpoint(); update(&state.annotations[index])
    }
    func deleteSelected() {
        guard let selectedID else { return }
        checkpoint(); state.annotations.removeAll { $0.id == selectedID }; self.selectedID = nil
    }
    func selectTool(_ value: EditorTool) {
        tool = value
        if value != .select { selectedID = nil }
        if value == .crop, let image { pendingCrop = state.crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height) }
        else { pendingCrop = nil }
    }
    func applyCrop() {
        guard let pendingCrop, pendingCrop.width >= 2, pendingCrop.height >= 2 else { return }
        checkpoint(); state.crop = pendingCrop.integral; self.pendingCrop = nil; tool = .select
    }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { try? await Task.sleep(for: .seconds(2.4)); guard !Task.isCancelled else { return }; toast = nil }
    }
}
