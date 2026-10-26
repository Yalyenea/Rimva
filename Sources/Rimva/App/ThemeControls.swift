import AppKit
import RimvaCore
import SwiftUI

/// Clear SwiftUI's initial control focus after mounting, including popover windows.
/// Updates leave user-selected responders alone so text entry and Tab still work.
struct InitialFocusReset: NSViewRepresentable {
    func makeNSView(context: Context) -> ResetView {
        let view = ResetView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ResetView, context: Context) {}

    final class ResetView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // SwiftUI chooses its initial focus while the hosting view is mounted.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      !(window.firstResponder is NSTextView) else { return }
                window.makeFirstResponder(nil)
            }
        }
    }
}

// Draw the control surfaces explicitly: macOS's standard bezels otherwise mix
// system gradients and white fills into the selected app palette.
struct ThemedSegments<Value: Hashable, Content: View>: View {
    @Binding var selection: Value
    var values: [Value]
    var equalWidth = true
    @ViewBuilder var label: (Value) -> Content
    @ObservedObject private var preferences = Preferences.shared
    @FocusState private var focusedValue: Value?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(values, id: \.self) { value in
                Button { selection = value } label: {
                    // Intrinsic text width plus padding keeps long theme names off the edges.
                    label(value).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: equalWidth ? .infinity : nil, minHeight: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SegmentStyle(selected: selection == value, focused: focusedValue == value, palette: preferences.palette))
                .focused($focusedValue, equals: value)
                .focusEffectDisabled()
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct SegmentStyle: ButtonStyle {
        var selected: Bool
        var focused: Bool
        var palette: ThemePalette
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(Color(nsColor: selected ? palette.accentText : palette.text))
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Color(nsColor: palette.selection) : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: palette.accent).opacity(focused ? 1 : selected ? 0.7 : 0), lineWidth: focused ? 1.5 : 1)
                }
                .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
        }
    }
}

struct ThemedToggleStyle: ToggleStyle {
    var compact = false
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let width: CGFloat = compact ? 27 : 31
        let height: CGFloat = compact ? 16 : 18
        let palette = preferences.palette
        return Button { configuration.isOn.toggle() } label: {
            Capsule().fill(Color(nsColor: configuration.isOn ? palette.accent : palette.elevated))
                .overlay {
                    Capsule().strokeBorder(Color(nsColor: palette.separator), lineWidth: 1)
                }
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color(nsColor: configuration.isOn ? palette.onAccent : palette.secondary))
                        .frame(width: height - 6, height: height - 6).padding(3)
                }
                .frame(width: width, height: height)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct ThemedActionStyle: ButtonStyle {
    var prominent = false
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = preferences.palette
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).frame(minHeight: 26)
            .foregroundStyle(Color(nsColor: prominent ? palette.onAccent : palette.text))
            .background(Color(nsColor: prominent ? palette.accent : palette.elevated), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: palette.separator).opacity(prominent ? 0 : 1), lineWidth: 1)
            }
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

struct ThemedSlider: NSViewRepresentable {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tickCount = 0
    var onEditingChanged: (Bool) -> Void = { _ in }
    @ObservedObject private var preferences = Preferences.shared
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ThemeSliderControl {
        let slider = ThemeSliderControl()
        slider.cell = ThemeSliderCell()
        slider.isContinuous = true
        slider.sliderType = .linear
        slider.focusRingType = .none
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: ThemeSliderControl, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = tickCount
        // Ticks are reference points; dragging still accepts every pixel value.
        slider.allowsTickMarkValuesOnly = false
        slider.doubleValue = value
        slider.isEnabled = isEnabled
        slider.onEditingChanged = onEditingChanged
        slider.setAccessibilityLabel(title)
        (slider.cell as? ThemeSliderCell)?.palette = preferences.palette
        slider.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var parent: ThemedSlider
        init(_ parent: ThemedSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue.rounded() }
    }
}

final class ThemeSliderControl: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onEditingChanged?(true)
        defer { onEditingChanged?(false) }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        onEditingChanged?(true)
        defer { onEditingChanged?(false) }
        super.keyDown(with: event)
    }
}

final class ThemeSliderCell: NSSliderCell {
    var palette = Preferences.shared.palette

    override func drawTickMarks() {
        palette.secondary.withAlphaComponent(isEnabled ? 0.65 : 0.25).setFill()
        for index in 0..<numberOfTickMarks {
            let tick = rectOfTickMark(at: index)
            // Small dots echo the round thumb without competing with its current position.
            let dot = NSRect(x: tick.midX - 1.5, y: tick.midY - 1.5, width: 3, height: 3)
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        palette.elevated.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        let fraction = max(0, min(1, (doubleValue - minValue) / max(1, maxValue - minValue)))
        var filled = bar
        filled.size.width *= fraction
        palette.accent.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let knob = NSRect(x: knobRect.midX - 5, y: knobRect.midY - 5, width: 10, height: 10)
        palette.accentText.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}
