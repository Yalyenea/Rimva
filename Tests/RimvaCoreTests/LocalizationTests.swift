import XCTest
@testable import RimvaCore

final class LocalizationTests: XCTestCase {
    func testLocalizedBundleUsesPackagedLanguageCasing() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".tmp/localization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, code) in ["zh-Hans", "zh-hans"].enumerated() {
            // Distinct names keep both fixtures separate on case-insensitive volumes.
            let bundleURL = directory.appendingPathComponent("case-\(index).bundle")
            let localizedURL = bundleURL.appendingPathComponent("\(code).lproj")
            try FileManager.default.createDirectory(at: localizedURL, withIntermediateDirectories: true)
            try "\"probe\" = \"中文\";".write(to: localizedURL.appendingPathComponent("Localizable.strings"),
                                          atomically: true, encoding: .utf8)
            let resources = try XCTUnwrap(Bundle(url: bundleURL))
            let localized = try XCTUnwrap(L10n.localizedBundle(for: "zh-Hans", in: resources))
            XCTAssertEqual(localized.bundleURL.lastPathComponent, "\(code).lproj")
            XCTAssertEqual(localized.localizedString(forKey: "probe", value: nil, table: nil), "中文")
            XCTAssertNil(L10n.localizedBundle(for: "fr", in: resources))
        }
    }

    func testLanguageSwitchUpdatesActionsAndPresetsImmediately() {
        let original = L10n.language
        defer { L10n.language = original }
        L10n.language = .english
        XCTAssertEqual(L("设置"), "Settings")
        XCTAssertEqual(BackgroundPreset.dawn.title, "Dawn · Gradient")
        XCTAssertEqual(BackgroundPreset.irisAbstract.title, "Iris · Abstract")
        L10n.language = .chinese
        XCTAssertEqual(L("设置"), "设置")
        XCTAssertEqual(BackgroundPreset.dawn.title, "晨曦 · 渐变")
        XCTAssertEqual(BackgroundPreset.irisAbstract.title, "鸢尾 · 抽象")
    }

    func testLocalizedErrorsPreserveTheirDynamicValues() {
        let original = L10n.language
        defer { L10n.language = original }
        for language in [AppLanguage.english, .chinese] {
            L10n.language = language
            let message = ImageRenderingError.invalidColor("#bad").localizedDescription
            XCTAssertTrue(message.contains("#bad"))
            XCTAssertFalse(message.contains("%@"))
            XCTAssertTrue(L("已保存到 %@", "Pictures").contains("Pictures"))
        }
    }
}
