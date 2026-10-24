import AppKit
import Combine
import ImageIO
import RimvaCore
import UniformTypeIdentifiers

struct BackgroundAsset: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: String { url.path }

    init(url: URL, name: String? = nil) {
        self.url = url.standardizedFileURL
        self.name = name ?? url.deletingPathExtension().lastPathComponent
    }
}

@MainActor
final class BackgroundLibrary: ObservableObject {
    static let shared = BackgroundLibrary()
    @Published private(set) var images: [BackgroundAsset] = []
    @Published private(set) var folders: [URL] = []
    @Published private(set) var wallpapers: [BackgroundAsset] = []
    @Published var error: String?

    private let storage = UserDefaults.standard
    private var imageURLs: [URL] = []
    private var folderAssets: [String: [BackgroundAsset]] = [:]
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    private init() {
        imageURLs = (storage.stringArray(forKey: "backgroundImagePaths") ?? []).map { URL(fileURLWithPath: $0) }
        folders = (storage.stringArray(forKey: "backgroundFolderPaths") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        refresh()
    }

    func addImages() {
        let panel = NSOpenPanel()
        panel.title = L("添加背景图片")
        panel.prompt = L("添加")
        panel.allowedContentTypes = Self.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        imageURLs = Self.unique(imageURLs + panel.urls)
        storage.set(imageURLs.map(\.path), forKey: "backgroundImagePaths")
        error = nil
        refresh()
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = L("添加图片文件夹")
        panel.prompt = L("添加")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        folders = Self.unique(folders + panel.urls)
        storage.set(folders.map(\.path), forKey: "backgroundFolderPaths")
        error = nil
        refresh()
    }

    func assets(in folder: URL) -> [BackgroundAsset] {
        folderAssets[folder.standardizedFileURL.path] ?? []
    }

    func refresh() {
        generation += 1
        let currentGeneration = generation
        refreshTask?.cancel()
        let imageURLs = imageURLs
        let folders = folders
        // File trees can contain thousands of originals; enumerate without blocking the editor.
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let images = Self.sortedAssets(imageURLs.filter(Self.isImage))
                var contents: [String: [BackgroundAsset]] = [:]
                var unreadableFolder: String?
                for folder in folders {
                    guard !Task.isCancelled else { break }
                    let scan = Self.scan(folder, system: false)
                    contents[folder.standardizedFileURL.path] = scan.assets
                    if scan.failed { unreadableFolder = folder.lastPathComponent }
                }
                let wallpapers = Self.sortedAssets(Self.wallpaperRoots.flatMap {
                    Self.scan($0, system: true).assets.map(\.url)
                })
                return (images, contents, wallpapers, unreadableFolder)
            }.value
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            self.images = result.0
            self.folderAssets = result.1
            self.wallpapers = result.2
            if let folder = result.3 { self.error = L("无法读取图片文件夹：%@", folder) }
        }
    }

    nonisolated private static var wallpaperRoots: [URL] {
        [
            "/System/Library/Desktop Pictures",
            "/Library/Desktop Pictures",
            NSHomeDirectory() + "/Library/Desktop Pictures",
            "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture",
            "/System/Library/AssetsV2/PreinstalledAssetsV2/com_apple_MobileAsset_DesktopPicture"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    nonisolated private static func scan(_ folder: URL, system: Bool) -> (assets: [BackgroundAsset], failed: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ([], !system)
        }
        var failed = false
        guard let iterator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [], errorHandler: { _, _ in failed = true; return true }
        ) else { return ([], !system) }
        var urls: [URL] = []
        for case let url as URL in iterator {
            guard !Task.isCancelled else { break }
            let name = url.lastPathComponent.lowercased()
            if system, name == ".thumbnails" || name.contains("thumbnail") {
                iterator.skipDescendants()
                continue
            }
            if isImage(url) { urls.append(url) }
        }
        return (sortedAssets(urls), failed)
    }

    nonisolated private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension),
              supportedTypes.contains(where: { type.conforms(to: $0) }) else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    nonisolated private static let supportedTypes = (CGImageSourceCopyTypeIdentifiers() as! [String]).compactMap { UTType($0) }

    nonisolated private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    nonisolated private static func sortedAssets(_ urls: [URL]) -> [BackgroundAsset] {
        unique(urls).map { BackgroundAsset(url: $0) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
