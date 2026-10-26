import AppKit
import RimvaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var hotKey: HotKey
    var onStyleEditingChanged: (Bool) -> Void = { _ in }
    @State private var previewAppearance: RenderAppearance = .light
    @State private var previewError: String?

    private var palette: ThemePalette { preferences.palette }
    private let optionWidth: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea().frame(height: 30)
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    let width = max(0, geometry.size.width - 48)
                    if geometry.size.width >= 800 {
                        // These are two content columns, so every setting stays visible without navigation.
                        HStack(alignment: .top, spacing: 28) {
                            preferencesColumn.frame(width: 336)
                            style(width: max(0, width - 364)).frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 24).padding(.bottom, 20)
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            preferencesColumn
                            style(width: width)
                        }
                        .padding(.horizontal, 24).padding(.bottom, 20)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: palette.text))
        .tint(Color(nsColor: palette.accentText))
        .background(Color(nsColor: palette.background))
        .environment(\.locale, L10n.locale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(InitialFocusReset())
        .focusEffectDisabled()
        .onAppear {
            preferences.refreshSystemStatus()
            previewAppearance = preferences.renderAppearance
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            preferences.refreshSystemStatus()
        }
    }

    private var preferencesColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(L("通用")) { general }
            section(L("截图")) { capture }
            section(L("保存")) { save }
            if let message = preferences.statusMessage { errorText(message) }
        }
    }

    private var general: some View {
        VStack(spacing: 0) {
            settingsRow(L("主题")) {
                ThemedSegments(selection: $preferences.theme, values: AppTheme.allCases) { Text($0.title) }
                    .frame(width: optionWidth).accessibilityLabel(L("主题"))
            }
            settingsRow(L("应用外观")) {
                ThemedSegments(selection: $preferences.appearance, values: AppAppearance.allCases) { Text($0.title) }
                    .frame(width: optionWidth).accessibilityLabel(L("应用外观"))
            }
            settingsRow(L("界面语言")) {
                ThemedSegments(selection: $preferences.language, values: AppLanguage.allCases) { Text($0.title) }
                    .frame(width: optionWidth).accessibilityLabel(L("界面语言"))
            }
            settingsRow(L("登录后静默启动")) {
                Toggle(L("登录后静默启动"), isOn: Binding(
                    get: { preferences.loginStatus == .enabled || preferences.loginStatus == .requiresApproval },
                    set: { preferences.setLaunchAtLogin($0) }
                )).labelsHidden().toggleStyle(ThemedToggleStyle())
            }
            if preferences.loginStatus == .requiresApproval {
                Button { SMAppService.openSystemSettingsLoginItems() } label: {
                    Label(L("打开登录设置"), systemImage: "arrow.up.forward.square")
                }.buttonStyle(.plain).padding(.top, 8)
            }
            settingsRow(L("隐藏菜单栏图标")) {
                Toggle(L("隐藏菜单栏图标"), isOn: $preferences.hidesMenuBarIcon)
                    .labelsHidden().toggleStyle(ThemedToggleStyle())
            }
            if preferences.hidesMenuBarIcon {
                Text(L("重新打开 Rimva，再按 ⌘, 进入设置。"))
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: palette.secondary))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }

    private var capture: some View {
        VStack(spacing: 0) {
            ForEach(ShortcutAction.allCases) { action in
                settingsRow(action.title) {
                    ShortcutRecorder(hotKey: hotKey, action: action, tint: palette.text)
                        .frame(width: 104, height: 26)
                }
            }
            if let error = hotKey.error { errorText(error).padding(.vertical, 8) }
            settingsRow(L("鼠标指针")) {
                Toggle(L("鼠标指针"), isOn: $preferences.includesCursor)
                    .labelsHidden().toggleStyle(ThemedToggleStyle())
            }
            settingsRow(L("自动复制")) {
                Toggle(L("自动复制"), isOn: $preferences.automaticCopy)
                    .labelsHidden().toggleStyle(ThemedToggleStyle())
            }
            settingsRow(L("截图后打开编辑器")) {
                Toggle(L("截图后打开编辑器"), isOn: $preferences.opensEditorAfterCapture)
                    .labelsHidden().toggleStyle(ThemedToggleStyle())
                    .help(L("关闭后，自动复制或保存成功便返回原应用。"))
            }
            settingsRow(L("屏幕录制")) {
                HStack(spacing: 10) {
                    Text(preferences.permissionGranted ? L("已授权") : L("未授权"))
                        .foregroundStyle(Color(nsColor: palette.secondary))
                    Button { CaptureCoordinator.openPermissionSettings() } label: {
                        Image(systemName: "arrow.up.forward.square").frame(width: 18, height: 26)
                    }
                    .buttonStyle(.plain).accessibilityLabel(L("打开权限设置…")).help(L("打开权限设置…"))
                }
            }
        }
    }

    private var save: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow(L("自动保存")) {
                Toggle(L("自动保存"), isOn: $preferences.automaticSave)
                    .labelsHidden().toggleStyle(ThemedToggleStyle())
                    .help(L("截图后自动保存到所选文件夹"))
            }
            HStack(spacing: 9) {
                Image(systemName: "folder").foregroundStyle(Color(nsColor: palette.secondary))
                Text((preferences.saveFolder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: palette.secondary))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(preferences.saveFolder.path)
                Spacer(minLength: 0)
                Button { preferences.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).accessibilityLabel(L("选择文件夹…")).help(L("选择文件夹…"))
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: preferences.saveFolder.path) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain).accessibilityLabel(L("显示保存文件夹")).help(L("显示保存文件夹"))
                .disabled(!FileManager.default.fileExists(atPath: preferences.saveFolder.path))
            }.frame(minHeight: 34)
            separator
            if let url = preferences.lastSavedURL, FileManager.default.fileExists(atPath: url.path) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label(L("显示上次图片"), systemImage: "arrow.up.forward.square")
                }.buttonStyle(.plain).padding(.top, 8)
            }
        }
    }

    private func style(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("样式"))
            StylePreview(style: preferences.defaultStyle, appearance: previewAppearance, error: $previewError)
                .frame(height: min(280, width / 1.6))
                .background(Color(nsColor: palette.canvas), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: palette.separator), lineWidth: 0.5))
                .accessibilityLabel(L("样式预览"))
            BackgroundStyleControls(style: $preferences.defaultStyle, onEditingChanged: onStyleEditingChanged)
            if let previewError { errorText(previewError) }
            BackgroundBrowser(style: $preferences.defaultStyle, previewAppearance: $previewAppearance)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(title)
            content()
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                control()
            }.frame(minHeight: 34)
            separator
        }
    }

    private var separator: some View {
        Rectangle().fill(Color(nsColor: palette.separator).opacity(0.45)).frame(height: 0.5)
    }

    private func errorText(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundStyle(Color(nsColor: palette.error))
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
