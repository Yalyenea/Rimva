import AppKit
import SwiftUI
import RimvaCore

struct CaptureHistoryView: View {
    @ObservedObject var history: CaptureHistory
    var canReturnToEditor: Bool
    var back: () -> Void
    var capture: () -> Void
    var open: (CaptureHistory.Entry) -> Void
    var copy: (CaptureHistory.Entry) -> Void
    var refresh: () -> Void
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("截图记录")).font(.system(size: 14, weight: .semibold))
                Text("\(history.entries.count)").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: preferences.palette.secondary))
                IconButton(title: L("刷新"), symbol: "arrow.clockwise", action: refresh)
                Spacer()
                if canReturnToEditor {
                    Button(L("返回编辑"), action: back).buttonStyle(ThemedActionStyle())
                }
            }
            .padding(.horizontal, 18).frame(height: 48)
            if history.entries.isEmpty {
                VStack(spacing: 14) {
                    if history.isLoading { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: "photo.stack").font(.system(size: 30, weight: .ultraLight))
                        Text(L("还没有截图")).font(.system(size: 13))
                        Button(L("开始截图"), action: capture).buttonStyle(ThemedActionStyle(prominent: true))
                    }
                }
                .foregroundStyle(Color(nsColor: preferences.palette.secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 12)], spacing: 12) {
                        ForEach(history.entries) { entry in
                            CaptureHistoryCard(history: history, entry: entry, open: { open(entry) }, copy: { copy(entry) })
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 18)
                }
            }
        }
        .background(Color.rimvaCanvas)
        .foregroundStyle(Color(nsColor: preferences.palette.text))
        .environment(\.locale, L10n.locale)
    }
}

private struct CaptureHistoryCard: View {
    let history: CaptureHistory
    let entry: CaptureHistory.Entry
    var open: () -> Void
    var copy: () -> Void
    @State private var thumbnail: NSImage?
    @State private var error: String?
    @State private var hovered = false
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            Button(action: open) {
                ZStack {
                    Color(nsColor: preferences.palette.elevated)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit().padding(10)
                    } else if let error {
                        Image(systemName: "exclamationmark.triangle").help(error)
                    } else { ProgressView().controlSize(.small) }
                }
                .frame(height: 146)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("在编辑器中打开"))
            .accessibilityLabel(L("打开截图 %@", date))
            HStack(spacing: 5) {
                Text(date).font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: preferences.palette.secondary))
                Spacer(minLength: 0)
                IconButton(title: L("复制截图"), symbol: "square.on.square", action: copy)
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(Color.rimvaSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color(nsColor: hovered ? preferences.palette.accent : preferences.palette.separator), lineWidth: 0.5))
        .onHover { hovered = $0 }
        .task(id: entry.id) {
            do {
                let image = try await history.thumbnail(for: entry)
                try Task.checkCancellation()
                thumbnail = NSImage(cgImage: image, size: .zero)
            } catch is CancellationError {
                // Offscreen cards release their preview work.
            } catch { self.error = error.localizedDescription }
        }
    }

    private var date: String {
        entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }
}
