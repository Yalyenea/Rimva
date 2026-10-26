import AppKit
import XCTest
@testable import Rimva

final class CaptureHistoryTests: XCTestCase {
    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/capture-history-tests-\(UUID().uuidString)")
    }

    private func image(width: Int = 80, height: Int = 40) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: 0.5))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor func testInitializationAndLoadingMissingDirectoryDoNotCreateFiles() async throws {
        let folder = directory()
        let history = CaptureHistory(directory: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try await history.load()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(history.isLoading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor func testReloadPreservesOriginalColorsTransparencyAndCaptureOrder() async throws {
        let folder = directory()
        let history = CaptureHistory(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = history.record(try image())
        let capture = try image(width: 120, height: 60)
        let second = history.record(capture)
        await history.flush()
        // Other PNG exports in the same directory do not become history entries.
        try ImageExporter.save(image(), to: folder.appendingPathComponent("unrelated.png"))
        let restored = CaptureHistory(directory: folder)
        try await restored.load()
        XCTAssertEqual(restored.entries.map(\.id), [second.id, first.id])
        let original = try await restored.image(for: try XCTUnwrap(restored.entries.first))
        XCTAssertEqual(original.width, 120)
        XCTAssertEqual(original.height, 60)
        let bitmap = NSBitmapImageRep(cgImage: original)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.001)
        let color = try XCTUnwrap(bitmap.colorAt(x: 60, y: 30)?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(NSBitmapImageRep(cgImage: capture).colorAt(x: 60, y: 30)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 1.0 / 255)
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 1.0 / 255)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
    }

    @MainActor func testImageIsReadableWhileItsWriteIsPending() async throws {
        let folder = directory()
        let history = CaptureHistory(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try image(width: 1200, height: 800)
        let entry = history.record(original)
        XCTAssertFalse(history.hasFailedWrites, "An in-progress write has not failed")
        let pending = try await history.image(for: entry)
        XCTAssertTrue(pending === original)
        XCTAssertEqual(history.entries.map(\.id), [entry.id])
        await history.flush()
        XCTAssertFalse(history.hasFailedWrites)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path))
        let persisted = try await history.image(for: entry)
        XCTAssertFalse(persisted === original, "Successful writes should release the pending full image")
    }

    @MainActor func testThumbnailDownsamplesLongCaptureAndPreservesProportions() async throws {
        let folder = directory()
        let history = CaptureHistory(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = history.record(try image(width: 800, height: 2400))
        let pending = try await history.thumbnail(for: entry)
        XCTAssertEqual(pending.width, 120)
        XCTAssertEqual(pending.height, 360)
        await history.flush()
        let thumbnail = try await history.thumbnail(for: entry)
        XCTAssertEqual(thumbnail.width, 120)
        XCTAssertEqual(thumbnail.height, 360)
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(cgImage: thumbnail).colorAt(x: 0, y: 0)).alphaComponent,
                       0, accuracy: 0.001)
    }

    @MainActor func testConcurrentLoadKeepsNewCapturesAndDoesNotDuplicateExistingOnes() async throws {
        let folder = directory()
        let initial = CaptureHistory(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = initial.record(try image())
        await initial.flush()
        let history = CaptureHistory(directory: folder)
        let loading = Task { try await history.load() }
        await Task.yield()
        let new = history.record(try image(width: 100))
        try await loading.value
        XCTAssertEqual(history.entries.map(\.id), [new.id, old.id],
                       "Completing a load must not replace captures recorded while it was running")
        await history.flush()
        try await history.load()
        XCTAssertEqual(history.entries.map(\.id), [new.id, old.id])
        XCTAssertFalse(history.isLoading)
    }

    @MainActor func testWriteFailureIsReportedAndOriginalRemainsReadable() async throws {
        let folder = directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocked = folder.appendingPathComponent("file-instead-of-directory")
        try Data("blocked".utf8).write(to: blocked)
        let history = CaptureHistory(directory: blocked)
        var errors: [Error] = []
        history.onError = { errors.append($0) }
        let original = try image()
        let entry = history.record(original)
        await history.flush()
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(history.hasFailedWrites, "Normal quit must preserve originals after a failed write")
        let retained = try await history.image(for: entry)
        XCTAssertTrue(retained === original)
        do {
            try await history.load()
            XCTFail("A path that is a file must report its enumeration error")
        } catch {
            XCTAssertFalse(history.isLoading)
        }
    }

    @MainActor func testLoadsOrdinarySavedPNGAndJPEGFilesInPlaceWithStableIDs() async throws {
        let folder = directory()
        let saved = folder.appendingPathComponent("saved")
        let archive = folder.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = try image()
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: capture).representation(using: .jpeg, properties: [:]))
        let names = ["Screenshot one.png", "Screenshot TWO.PNG", "photo.JPG", "photo.JpEg"]
        for name in names {
            let url = saved.appendingPathComponent(name)
            if url.pathExtension.lowercased() == "png" {
                try ImageExporter.save(capture, to: url)
            } else {
                try jpeg.write(to: url)
            }
        }
        try Data("ignored".utf8).write(to: saved.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: saved.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
        let history = CaptureHistory(directory: archive)
        try await history.load(savedDirectory: saved)
        XCTAssertEqual(Set(history.entries.map { $0.fileURL.lastPathComponent }), Set(names))
        XCTAssertTrue(history.entries.allSatisfy { $0.fileURL.deletingLastPathComponent().path == saved.path })
        let ids = Dictionary(uniqueKeysWithValues: history.entries.map { ($0.fileURL, $0.id) })
        for entry in history.entries {
            let original = try await history.image(for: entry)
            XCTAssertEqual(original.width, 80)
        }
        try await history.load(savedDirectory: saved)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: history.entries.map { ($0.fileURL, $0.id) }), ids)
        let rebuilt = CaptureHistory(directory: archive)
        try await rebuilt.load(savedDirectory: saved)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rebuilt.entries.map { ($0.fileURL, $0.id) }), ids)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path), "Browsing saved images must not copy them into the archive")
    }

    @MainActor func testChangingSavedDirectoryAndRefreshingRemovesOldExternalEntries() async throws {
        let folder = directory()
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstFile = first.appendingPathComponent("first.png")
        let secondFile = second.appendingPathComponent("second.png")
        try ImageExporter.save(image(), to: firstFile)
        try ImageExporter.save(image(), to: secondFile)
        let history = CaptureHistory(directory: folder.appendingPathComponent("archive"))
        let archived = history.record(try image())
        await history.flush()
        try await history.load(savedDirectory: first)
        XCTAssertEqual(Set(history.entries.map(\.fileURL)), [archived.fileURL, firstFile])
        try await history.load(savedDirectory: second)
        XCTAssertEqual(Set(history.entries.map(\.fileURL)), [archived.fileURL, secondFile])
        try FileManager.default.removeItem(at: secondFile)
        try await history.load(savedDirectory: second)
        XCTAssertEqual(history.entries.map(\.id), [archived.id])
        try await history.load(savedDirectory: first)
        try await history.load()
        XCTAssertEqual(history.entries.map(\.id), [archived.id])
    }

    @MainActor func testSavedFileAssociationDeduplicatesAfterRestartAndKeepsTheOriginal() async throws {
        let folder = directory()
        let saved = folder.appendingPathComponent("saved")
        let archive = folder.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exported = saved.appendingPathComponent("Screenshot.png")
        try ImageExporter.save(image(width: 40), to: exported)
        let bytes = try Data(contentsOf: exported)
        let history = CaptureHistory(directory: archive)
        try await history.load(savedDirectory: saved)
        XCTAssertEqual(history.entries.count, 1)
        let recorded = history.record(try image(width: 120), savedFile: exported)
        XCTAssertEqual(history.entries.map(\.id), [recorded.id])
        try await history.load(savedDirectory: saved)
        XCTAssertEqual(history.entries.map(\.id), [recorded.id],
                       "An in-flight archive write must already represent its saved export")
        await history.flush()
        let rebuilt = CaptureHistory(directory: archive)
        try await rebuilt.load(savedDirectory: saved)
        XCTAssertEqual(rebuilt.entries.map(\.id), [recorded.id])
        XCTAssertEqual(rebuilt.entries.first?.savedFileURL, exported)
        let original = try await rebuilt.image(for: try XCTUnwrap(rebuilt.entries.first))
        XCTAssertEqual(original.width, 120)
        XCTAssertEqual(try Data(contentsOf: exported), bytes, "History must never rewrite a user's export")
    }

    @MainActor func testLatestSavedDirectoryLoadWinsOverAnEarlierRequest() async throws {
        let folder = directory()
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try ImageExporter.png(image())
        // More entries keep the first directory scan busy while the second request starts.
        for index in 0..<160 { try png.write(to: first.appendingPathComponent("old-\(index).png")) }
        let current = second.appendingPathComponent("current.png")
        try png.write(to: current)
        let history = CaptureHistory(directory: folder.appendingPathComponent("archive"))
        let oldLoad = Task { try await history.load(savedDirectory: first) }
        await Task.yield()
        try await history.load(savedDirectory: second)
        try await oldLoad.value
        XCTAssertEqual(history.entries.map(\.fileURL), [current])
        XCTAssertFalse(history.isLoading)
    }

    @MainActor func testCorruptAssociationFailsLoadingExplicitly() async throws {
        let folder = directory()
        let history = CaptureHistory(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorded = history.record(try image(), savedFile: folder.appendingPathComponent("export.png"))
        await history.flush()
        let sidecar = recorded.fileURL.deletingPathExtension().appendingPathExtension("json")
        try Data("invalid json".utf8).write(to: sidecar)
        let rebuilt = CaptureHistory(directory: folder)
        do {
            try await rebuilt.load()
            XCTFail("A corrupt export association must be reported")
        } catch {
            XCTAssertTrue(error is DecodingError)
            XCTAssertFalse(rebuilt.isLoading)
        }
    }

    @MainActor func testAssociationWriteFailureReportsTheErrorAndRetainsOriginal() async throws {
        let folder = directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = CaptureHistory(directory: folder)
        var errors: [Error] = []
        history.onError = { errors.append($0) }
        let capture = try image()
        let recorded = history.record(capture, savedFile: folder.appendingPathComponent("export.png"))
        let sidecar = recorded.fileURL.deletingPathExtension().appendingPathExtension("json")
        // record's write task starts after this actor yields, so the blocked path is deterministic.
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        await history.flush()
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(history.hasFailedWrites)
        let retained = try await history.image(for: recorded)
        XCTAssertTrue(retained === capture)
    }
}
