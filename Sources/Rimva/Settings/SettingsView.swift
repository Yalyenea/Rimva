import AppKit
import RimvaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var hotKey: HotKey
    @State private var previewAppearance: RenderAppearance = .light
    @State private var previewError: String?

    private var palette: ThemePalette { preferences.palette }
    private let optionWidth: CGFloat = 208

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea().frame(height: 30)
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    let width = max(0, geometry.size.width - 48)
                    if geometry.size.width >= 760 {
                        // These are two content columns, so every setting stays visible without navigation.
                        HStack(alignment: .top, spacing: 24) {
                            preferencesColumn.frame(width: 304)
                            style(width: max(0, width - 328)).frame(maxWidth: .infinity)
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
        .tint(Color(nsColor: palette.accent))
        .background(Color(nsColor: palette.background))
        .environment(\.locale, L10n.locale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear { preferences.refreshSystemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            preferences.refreshSystemStatus()
        }
    }

    private var preferencesColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
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
            settingsRow(L("登录启动")) {
                Toggle(L("登录启动"), isOn: Binding(
                    get: { preferences.loginStatus == .enabled || preferences.loginStatus == .requiresApproval },
                    set: { preferences.setLaunchAtLogin($0) }
                )).labelsHidden().toggleStyle(ThemedToggleStyle())
            }
            if preferences.loginStatus == .requiresApproval {
                Button { SMAppService.openSystemSettingsLoginItems() } label: {
                    Label(L("打开登录设置"), systemImage: "arrow.up.forward.square")
                }.buttonStyle(.plain).padding(.top, 8)
            }
        }
    }

    private var capture: some View {
        VStack(spacing: 0) {
            ForEach(ShortcutAction.allCases) { action in
                settingsRow(action.title) {
                    HStack(spacing: 8) {
                        ShortcutRecorder(hotKey: hotKey, action: action, tint: palette.text)
                            .frame(width: 104, height: 26)
                        if hotKey.combination(for: action) != nil {
                            Button { hotKey.set(nil, for: action) } label: {
                                Image(systemName: "xmark.circle").frame(width: 14, height: 26)
                            }
                            .buttonStyle(.plain).foregroundStyle(Color(nsColor: palette.secondary))
                            .accessibilityLabel(L("清除快捷键")).help(L("清除快捷键"))
                        }
                    }
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
            settingsRow(L("屏幕访问")) {
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
            HStack(spacing: 9) {
                Image(systemName: "folder").foregroundStyle(Color(nsColor: palette.secondary))
                Text(preferences.saveFolder.path)
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
            }.frame(minHeight: 32)
            separator
            settingsRow(L("图片格式")) { Text("PNG").foregroundStyle(Color(nsColor: palette.secondary)) }
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
                .frame(height: min(335, width / 1.55))
                .background(Color(nsColor: palette.canvas), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: palette.separator), lineWidth: 0.5))
                .accessibilityLabel(L("样式预览"))
            styleControls
            if let previewError { errorText(previewError) }
            BackgroundBrowser(style: $preferences.defaultStyle, previewAppearance: $previewAppearance)
        }
    }

    private var styleControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                compactToggle(L("背景"), isOn: styleBinding(\.enabled))
                compactToggle(L("跟随外观"), isOn: styleBinding(\.followsAppearance))
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 4) {
                    sliderLabel(L("留白间距"), value: Int(preferences.defaultStyle.padding))
                    ThemedSlider(title: L("留白间距"), value: styleSlider(\.padding), range: 0...160).frame(height: 20)
                }
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Text(L("圆角半径")).lineLimit(1)
                        Spacer(minLength: 4)
                        Toggle(L("圆角半径"), isOn: styleBinding(\.rounded))
                            .labelsHidden().toggleStyle(ThemedToggleStyle(compact: true))
                        Text("\(Int(preferences.defaultStyle.radius))")
                            .monospacedDigit().foregroundStyle(Color(nsColor: palette.secondary))
                            .frame(width: 20, alignment: .trailing)
                    }.frame(height: 26)
                    ThemedSlider(title: L("圆角半径"), value: styleSlider(\.radius), range: 0...40)
                        .frame(height: 20).disabled(!preferences.defaultStyle.rounded)
                }
            }.disabled(!preferences.defaultStyle.enabled)
            HStack {
                Text(L("投射阴影"))
                Spacer(minLength: 12)
                ThemedSegments(selection: styleBinding(\.shadow), values: ShadowStyle.allCases) { Text($0.title) }
                    .frame(width: 208).accessibilityLabel(L("投射阴影"))
            }.disabled(!preferences.defaultStyle.enabled)
        }
        .controlSize(.small)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(title)
            content()
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 8)
                control()
            }.frame(minHeight: 32)
            separator
        }
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(ThemedToggleStyle())
        }.frame(maxWidth: .infinity, minHeight: 26)
    }

    private func sliderLabel(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text("\(value) px").monospacedDigit().foregroundStyle(Color(nsColor: palette.secondary))
        }.frame(height: 26)
    }

    private var separator: some View {
        Rectangle().fill(Color(nsColor: palette.separator).opacity(0.65)).frame(height: 0.5)
    }

    private func styleBinding<Value>(_ keyPath: WritableKeyPath<RimvaCore.BackgroundStyle, Value>) -> Binding<Value> {
        Binding(get: { preferences.defaultStyle[keyPath: keyPath] },
                set: { preferences.defaultStyle[keyPath: keyPath] = $0 })
    }

    private func styleSlider(_ keyPath: WritableKeyPath<RimvaCore.BackgroundStyle, Double>) -> Binding<Double> {
        Binding(get: { preferences.defaultStyle[keyPath: keyPath] },
                set: { preferences.defaultStyle[keyPath: keyPath] = $0.rounded() })
    }

    private func errorText(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundStyle(Color(nsColor: palette.error))
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
