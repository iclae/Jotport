#if os(macOS)
import AppKit
import XCTest
import JotportCore
@testable import Jotport

final class ScratchpadSearchTests: XCTestCase {
    func testRevealFocusCompositionAndEscapeRestore() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 444, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panel = ScratchpadSearch()
        window.contentView!.addSubview(panel.view)
        panel.view.frame = NSRect(x: 12, y: 20, width: 420, height: 70)
        XCTAssertFalse(panel.isOpen)
        panel.open(in: window)
        XCTAssertTrue(panel.isOpen)
        XCTAssertNotNil(panel.field.currentEditor())
        panel.field.stringValue = "中文"
        panel.includeArchived.state = .on
        var changed = 0, closed = 0
        panel.changed = { changed += 1 }
        panel.closed = { closed += 1 }
        XCTAssertFalse(panel.close(composing: true))
        XCTAssertTrue(panel.isOpen)
        XCTAssertEqual(panel.field.stringValue, "中文")
        XCTAssertTrue(panel.close())
        XCTAssertFalse(panel.isOpen)
        XCTAssertEqual(panel.field.stringValue, "")
        XCTAssertEqual(panel.includeArchived.state, .off)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(panel.close())
    }

    func testSearchContinuesToUseExistingArchiveAndSessionMatching() {
        var block = Block()
        block.body = "草稿\n第二行"
        block.association = Association(agent: "codex", directory: "/project")
        block.association?.sessionID = "Native-ID"
        XCTAssertTrue(Reducer.matches(block, query: "第二行", archived: false))
        XCTAssertTrue(Reducer.matches(block, query: "native-id", archived: false))
        block.archived = true
        XCTAssertFalse(Reducer.matches(block, query: "草稿", archived: false))
        XCTAssertTrue(Reducer.matches(block, query: "草稿", archived: true))
        block.deleted = true
        XCTAssertFalse(Reducer.matches(block, query: "", archived: true))
    }
}
#endif
