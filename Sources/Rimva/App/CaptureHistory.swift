import Combine
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Original captures are kept on disk; only images awaiting a successful write stay in memory.
@MainActor final class CaptureHistory: ObservableObject {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let fileURL: URL
        let savedFileURL: URL?

        init(id: UUID, createdAt: Date, fileURL: URL, savedFileURL: URL? = nil) {
            self.id = id
            self.createdAt = createdAt
            self.fileURL = fileURL
            self.savedFileURL = savedFileURL
        }
    }

    private struct ExportAssociation: Codable {
        let savedFileURL: URL
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoading = false
    var onError: ((Error) -> Void)?
    var hasFailedWrites: Bool { pendingImages.keys.contains { pendingWrites[$0] == nil } }

    private let directory: URL
    private var pendingImages: [UUID: CGImage] = [:]
    private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    private var loadingCount = 0
    private var loadGeneration = 0
    private var recordedEntries: [UUID: Entry] = [:]
    nonisolated private static let filenamePrefix = "rimva-capture-"

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rimva/Captures", isDirectory: true)) {
        self.directory = directory
    }

    func load(savedDirectory: URL? = nil) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        loadingCount += 1
        isLoading = true
        defer {
            loadingCount -= 1
            isLoading = loadingCount > 0
        }
        let directory = directory
        let loaded = try await Task.detached(priority: .utility) {
            let archived = try Self.readArchivedEntries(in: directory)
            let saved = try savedDirectory.map { try Self.readSavedEntries(in: $0) } ?? []
            return (archived, saved)
        }.value
        // Folder changes can finish out of order; only the latest request controls the visible list.
        guard generation == loadGeneration else { return }
        // A capture can arrive while directory enumeration is suspended. Keep those entries.
        var archived = Dictionary(loaded.0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in recordedEntries.values { archived[entry.id] = entry }
        let representedPaths = Set(archived.values.flatMap { entry in
            [entry.fileURL, entry.savedFileURL].compactMap { $0?.standardizedFileURL.path }
        })
        entries = Self.sorted(Array(archived.values) + loaded.1.filter {
            !representedPaths.contains($0.fileURL.standardizedFileURL.path)
        })
    }

    @discardableResult func record(_ image: CGImage, savedFile: URL? = nil) -> Entry {
        let id = UUID()
        let entry = Entry(id: id, createdAt: Date(),
                          fileURL: directory.appendingPathComponent("\(Self.filenamePrefix)\(id.uuidString).png"),
                          savedFileURL: savedFile?.standardizedFileURL)
        recordedEntries[id] = entry
        pendingImages[id] = image
        entries = Self.sorted(entries.filter {
            entry.savedFileURL == nil || $0.fileURL.standardizedFileURL != entry.savedFileURL
        } + [entry])
        let directory = directory
        pendingWrites[id] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
                Result {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try ImageExporter.save(image, to: entry.fileURL)
                    // Atomic writes create a new inode; set its date after the final replacement.
                    try FileManager.default.setAttributes([.creationDate: entry.createdAt], ofItemAtPath: entry.fileURL.path)
                    if let savedFileURL = entry.savedFileURL {
                        let association = ExportAssociation(savedFileURL: savedFileURL)
                        try JSONEncoder().encode(association).write(to: Self.associationURL(for: entry.fileURL), options: .atomic)
                    }
                }
            }.value
            guard let self else { return }
            self.pendingWrites[id] = nil
            switch result {
            case .success:
                self.pendingImages[id] = nil
            case let .failure(error):
                // Retain an unsaved original so a disk error cannot discard the capture.
                self.onError?(error)
            }
        }
        return entry
    }

    func flush() async {
        while !pendingWrites.isEmpty {
            let writes = Array(pendingWrites.values)
            for write in writes { await write.value }
        }
    }

    func image(for entry: Entry) async throws -> CGImage {
        if let image = pendingImages[entry.id] { return image }
        return try await Task.detached(priority: .userInitiated) {
            try ImageExporter.read(entry.fileURL)
        }.value
    }

    func thumbnail(for entry: Entry) async throws -> CGImage {
        let pendingImage = pendingImages[entry.id]
        return try await Task.detached(priority: .utility) {
            if let pendingImage {
                // Pending captures already have pixels; scale directly instead of encoding a second full PNG.
                let scale = min(1, 360 / CGFloat(max(pendingImage.width, pendingImage.height)))
                let width = max(1, Int((CGFloat(pendingImage.width) * scale).rounded()))
                let height = max(1, Int((CGFloat(pendingImage.height) * scale).rounded()))
                guard let colorSpace = pendingImage.colorSpace,
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw ExportError.undecodable
                }
                context.interpolationQuality = .high
                context.draw(pendingImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let thumbnail = context.makeImage() else { throw ExportError.undecodable }
                return thumbnail
            }
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(entry.fileURL as CFURL, sourceOptions) else {
                throw ExportError.unreadable
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 360,
                                          kCGImageSourceShouldCacheImmediately: true]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ExportError.undecodable
            }
            return thumbnail
        }.value
    }

    nonisolated private static func files(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return []
        }
    }

    nonisolated private static func readArchivedEntries(in directory: URL) throws -> [Entry] {
        try files(in: directory).compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "png", name.hasPrefix(filenamePrefix),
                  let id = UUID(uuidString: String(name.dropFirst(filenamePrefix.count))) else { return nil }
            let values = try url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            guard let createdAt = values.creationDate else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
            }
            let association: ExportAssociation?
            do {
                association = try JSONDecoder().decode(ExportAssociation.self,
                                                      from: Data(contentsOf: associationURL(for: url)))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                association = nil
            }
            return Entry(id: id, createdAt: createdAt, fileURL: url, savedFileURL: association?.savedFileURL)
        }
    }

    nonisolated private static func readSavedEntries(in directory: URL) throws -> [Entry] {
        try files(in: directory).compactMap { url in
            guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
            let values = try url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            guard let createdAt = values.creationDate else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
            }
            let url = url.standardizedFileURL
            return Entry(id: stableID(for: url), createdAt: createdAt, fileURL: url)
        }
    }

    nonisolated private static func associationURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("json")
    }

    nonisolated private static func stableID(for url: URL) -> UUID {
        // Path-based IDs survive refreshes and restarts without writing into the user's folder.
        let bytes = Array(SHA256.hash(data: Data(url.path.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    nonisolated private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }
}
