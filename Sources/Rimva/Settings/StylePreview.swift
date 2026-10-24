import AppKit
import RimvaCore
import SwiftUI

/// Settings draws with the export renderer, so spacing, image backgrounds and shadows stay accurate.
struct StylePreview: NSViewRepresentable {
    var style: RimvaCore.BackgroundStyle
    var appearance: RenderAppearance
    @Binding var error: String?

    func makeNSView(context: Context) -> StylePreviewView {
        let view = StylePreviewView()
        view.source = SampleImage.make()
        return view
    }

    func updateNSView(_ view: StylePreviewView, context: Context) {
        view.style = style
        view.renderAppearance = appearance
        view.onError = { error = $0 }
        view.needsDisplay = true
    }
}

final class StylePreviewView: NSView {
    var source: CGImage?
    var style = RimvaCore.BackgroundStyle()
    var renderAppearance = RenderAppearance.light
    var onError: ((String?) -> Void)?
    private var lastError: String?
    private var hasReported = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = source, let context = NSGraphicsContext.current?.cgContext else { return }
        var previewStyle = style
        // Previewing the moon slot must show its assignment even while automatic switching is off.
        previewStyle.followsAppearance = true
        let size = RimvaCore.ImageRenderer.outputSize(image: image, state: EditState(), style: previewStyle)
        guard size.width > 0, size.height > 0 else {
            report(L("留白或圆角数值无效。"))
            return
        }
        let available = bounds.insetBy(dx: 14, dy: 14)
        let scale = min(available.width / size.width, available.height / size.height)
        guard scale > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.midX - size.width * scale / 2, y: bounds.midY - size.height * scale / 2)
        context.scaleBy(x: scale, y: scale)
        do {
            try RimvaCore.ImageRenderer.draw(image: image, state: EditState(), style: previewStyle, appearance: renderAppearance, in: context)
            report(nil)
        } catch { report(error.localizedDescription) }
    }

    private func report(_ error: String?) {
        guard !hasReported || error != lastError else { return }
        hasReported = true
        lastError = error
        // Drawing must finish before SwiftUI publishes the matching inline error.
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
