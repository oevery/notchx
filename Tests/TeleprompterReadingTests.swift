import XCTest
@testable import NotchX

final class TeleprompterReadingTests: XCTestCase {
    func testParagraphOffsetsUseDisplayedCharactersAcrossChineseEmojiAndCRLF() {
        let text = "Hello 👋\r\n\r\n第二段内容\rFinal"
        let paragraphs = TeleprompterParagraph.parse(text)
        XCTAssertEqual(paragraphs.map(\.title), ["Hello 👋", "第二段内容", "Final"])
        XCTAssertEqual(paragraphs.map(\.id), [0, 9, 15])
        let display = TeleprompterTextTokenizer.displayText(from: text)
        for paragraph in paragraphs { XCTAssertTrue(String(display.dropFirst(paragraph.id)).hasPrefix(paragraph.title)) }
    }

    func testShortcutPolicyPreservesTextEditingModifiersAndHeldSpace() {
        XCTAssertEqual(TeleprompterKeyboardAction.resolve(keyCode: 49, hasModifiers: false, isRepeat: false, isEditing: false), .playPause)
        XCTAssertNil(TeleprompterKeyboardAction.resolve(keyCode: 49, hasModifiers: false, isRepeat: true, isEditing: false))
        for key: UInt16 in [49, 53, 24, 27, 125, 126] {
            XCTAssertNil(TeleprompterKeyboardAction.resolve(keyCode: key, hasModifiers: true, isRepeat: false, isEditing: false))
            XCTAssertNil(TeleprompterKeyboardAction.resolve(keyCode: key, hasModifiers: false, isRepeat: false, isEditing: true))
        }
        XCTAssertEqual(TeleprompterKeyboardAction.resolve(keyCode: 125, hasModifiers: false, isRepeat: false, isEditing: false), .nextParagraph)
    }

    @MainActor
    func testParagraphLayoutProducesARealLinePositionWithNarrowReadingColumn() {
        let text = "First paragraph with several words.\n第二段带有中文和 👋 表情。\nLast paragraph."
        let second = TeleprompterParagraph.parse(text)[1]
        let wide = TeleprompterLineLayout.position(forCharacterOffset: second.id, in: text, width: 600, fontSize: 22, lineSpacing: 7.7, alignment: .leading)
        let narrow = TeleprompterLineLayout.position(forCharacterOffset: second.id, in: text, width: 180, fontSize: 22, lineSpacing: 7.7, alignment: .leading)
        XCTAssertGreaterThan(wide.top, 0)
        XCTAssertGreaterThanOrEqual(narrow.top, wide.top)
        XCTAssertGreaterThan(narrow.index, 0)
        let offsets = TeleprompterParagraph.parse(text).map(\.id)
        let positions = TeleprompterLineLayout.positions(forCharacterOffsets: offsets, in: text, width: 180, fontSize: 22, lineSpacing: 7.7, alignment: .leading)
        XCTAssertEqual(positions[1], narrow)
        XCTAssertEqual(positions[0].top, 0)
        XCTAssertGreaterThan(positions[2].top, positions[1].top)
    }
}
