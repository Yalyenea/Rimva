import AppKit
import Combine
import RimvaCore
import ServiceManagement

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return L("跟随系统"); case .light: return L("浅色"); case .dark: return L("深色") } }
    var native: NSAppearance? { switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) } }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let storage = UserDefaults.standard
    @Published var defaultStyle: BackgroundStyle { didSet { saveStyle() } }
    @Published var includesCursor: Bool { didSet { storage.set(includesCursor, forKey: "includesCursor") } }
    @Published var appearance: AppAppearance {
        didSet {
            storage.set(appearance.rawValue, forKey: "appearance")
            NSApp.appearance = appearance.native
            notifyThemeChanged()
        }
    }
    @Published var theme: AppTheme {
        didSet {
            storage.set(theme.rawValue, forKey: "theme")
            notifyThemeChanged()
        }
    }
    @Published var automaticCopy: Bool { didSet { storage.set(automaticCopy, forKey: "automaticCopy") } }
    @Published var language: AppLanguage {
        didSet {
            storage.set(language.rawValue, forKey: "appLanguage")
            L10n.language = language
            statusMessage = nil
            NotificationCenter.default.post(name: .rimvaLanguageChanged, object: nil)
        }
    }
    @Published var saveFolder: URL { didSet { storage.set(saveFolder.path, forKey: "saveFolder") } }
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var permissionGranted = false
    @Published var statusMessage: String?
    @Published var lastSavedURL: URL?

    var palette: ThemePalette { theme.dynamicPalette }
    var renderAppearance: RenderAppearance {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private var appearanceObservation: NSKeyValueObservation?
    private var languageSubscription: AnyCancellable?
    private var preferredLanguages = Locale.preferredLanguages

    private init() {
        let savedLanguage = AppLanguage(rawValue: storage.string(forKey: "appLanguage") ?? "system") ?? .system
        language = savedLanguage
        L10n.language = savedLanguage
        if let data = storage.data(forKey: "defaultStyle"), let style = try? JSONDecoder().decode(BackgroundStyle.self, from: data) {
            defaultStyle = style
        } else { defaultStyle = BackgroundStyle() }
        includesCursor = storage.bool(forKey: "includesCursor")
        appearance = AppAppearance(rawValue: storage.string(forKey: "appearance") ?? "system") ?? .system
        theme = AppTheme(rawValue: storage.string(forKey: "theme") ?? "rosePine") ?? .rosePine
        automaticCopy = storage.bool(forKey: "automaticCopy")
        let path = storage.string(forKey: "saveFolder") ?? NSHomeDirectory() + "/Pictures/Rimva"
        saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        NSApp.appearance = appearance.native
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                self?.notifyThemeChanged()
            }
        }
        languageSubscription = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSystemLanguage() }
        refreshSystemStatus()
    }

    private func notifyThemeChanged() {
        NotificationCenter.default.post(name: .rimvaThemeChanged, object: nil)
    }

    private func refreshSystemLanguage() {
        let current = Locale.preferredLanguages
        guard current != preferredLanguages else { return }
        preferredLanguages = current
        guard language == .system else { return }
        objectWillChange.send()
        NotificationCenter.default.post(name: .rimvaLanguageChanged, object: nil)
    }

    private func saveStyle() {
        do { storage.set(try JSONEncoder().encode(defaultStyle), forKey: "defaultStyle") }
        catch { statusMessage = L("默认样式未能保存。%@", error.localizedDescription) }
    }

    func refreshSystemStatus() {
        loginStatus = SMAppService.mainApp.status
        permissionGranted = CaptureCoordinator.permissionGranted
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            statusMessage = nil
        } catch { statusMessage = L("登录启动设置失败。%@", error.localizedDescription) }
        refreshSystemStatus()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L("选择保存位置")
        panel.prompt = L("选择")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }
}
