import XCTest
@testable import RimvaCore

final class LocalizationTests: XCTestCase {
    func testLanguageSwitchUpdatesActionsAndPresetsImmediately() {
        let original = L10n.language
        defer { L10n.language = original }
        L10n.language = .english
        XCTAssertEqual(L("设置"), "Settings")
        XCTAssertEqual(BackgroundPreset.mist.title, "Mist")
        L10n.language = .chinese
        XCTAssertEqual(L("设置"), "设置")
        XCTAssertEqual(BackgroundPreset.mist.title, "晨雾")
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
