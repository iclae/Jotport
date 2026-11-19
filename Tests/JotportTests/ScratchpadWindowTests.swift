#if os(macOS)
import AppKit
import XCTest
import JotportCore
@testable import Jotport

final class ScratchpadWindowTests: XCTestCase {
    private func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
    private func click(_ button: NSButton, in window: NSWindow) throws {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        pump()
    }
    private func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
        pump()
    }

    func testRealWindowSearchRoutingPinAndPopulatedCaptures() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = App()
        app.store = try Store(path: root.appendingPathComponent("fixture.sqlite").path)
        let bodies = ["排查窄窗下的按钮点击\n先检查浮层会不会挡住交互。", "整理记忆试点口径\n同一任务、同一模型，只换记忆输入。", "Jotport 测试随记\n和终端并排时，试试中文输入。"]
        app.blocks = bodies.enumerated().map { i, body in
            var block = Block(); block.body = body; block.order = Double(i)
            if i == 0 {
                block.association = Association(agent: "pi", directory: root.path)
                block.association?.sessionID = "fixture-only"
                block.run = Run(snapshot: body); block.run?.status = "结果待查看"
            }
            return block
        }
        for block in app.blocks { try app.store.save(block) }
        let original = try app.store.load()
        app.buildUI(); app.reload()
        let window = try XCTUnwrap(app.window)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(nil); pump()
        XCTAssertEqual(window.frame.width, 444)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(app.windowPin.identifier?.rawValue, "pin")
        try capture(window, name: "01-normal-unpinned")

        for query in ["", "窄窗", "没有匹配"] {
            try click(app.searchButton, in: window)
            XCTAssertTrue(app.searchPanel.isOpen)
            XCTAssertNotNil(app.search.currentEditor())
            app.search.stringValue = query; app.refresh()
            try click(app.searchButton, in: window)
            XCTAssertFalse(app.searchPanel.isOpen)
            XCTAssertEqual(app.search.stringValue, "")
            XCTAssertEqual(app.include.state, .off)
        }
        for query in ["", "窄窗"] {
            try key(3, characters: "f", flags: .command, in: window)
            XCTAssertTrue(app.searchPanel.isOpen)
            let editor = try XCTUnwrap(app.search.currentEditor() as? NSTextView)
            editor.string = query
            try key(53, characters: "\u{1b}", in: window)
            XCTAssertFalse(app.searchPanel.isOpen)
            XCTAssertEqual(app.search.stringValue, "")
            XCTAssertFalse(window.firstResponder === editor)
        }
        app.openSearch(); pump()
        let editor = try XCTUnwrap(app.search.currentEditor() as? NSTextView)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        try key(53, characters: "\u{1b}", in: window)
        XCTAssertTrue(app.searchPanel.isOpen, "Composition Escape must not dismiss search")
        editor.unmarkText() // Deterministic synthetic composition completion; real IME remains manual acceptance.
        try key(53, characters: "\u{1b}", in: window)
        XCTAssertFalse(app.searchPanel.isOpen)

        app.openSearch(); app.search.stringValue = "窄窗"; app.refresh(); pump()
        try capture(window, name: "02-search-unpinned")
        try click(app.searchPanel.closeButton, in: window)
        XCTAssertFalse(app.searchPanel.isOpen)
        try click(app.windowPin, in: window)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(app.windowPin.identifier?.rawValue, "pin.fill")
        XCTAssertEqual(app.windowPin.toolTip, "取消窗口置顶")
        window.makeFirstResponder(nil); pump()
        try capture(window, name: "03-normal-pinned")
        app.openSearch(); app.search.stringValue = "窄窗"; app.refresh(); pump()
        try capture(window, name: "04-search-pinned")
        app.searchPanel.close()
        try click(app.windowPin, in: window)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(app.windowPin.identifier?.rawValue, "pin")
        XCTAssertEqual(try app.store.load(), original, "UI routing must not change note storage or agent state")
        try makeContactSheet()
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["JOTPORT_UI_EVIDENCE"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        window.displayIfNeeded(); pump()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory + "/" + name + ".png"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
    private func makeContactSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["JOTPORT_UI_EVIDENCE"] else { return }
        let names = ["01-normal-unpinned", "02-search-unpinned", "03-normal-pinned", "04-search-pinned"]
        let labels = ["普通 · 未置顶", "搜索 · 未置顶", "普通 · 已置顶", "搜索 · 已置顶"]
        let sheet = NSImage(size: NSSize(width: 952, height: 808))
        sheet.lockFocus()
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 952, height: 808).fill()
        ("Jotport · 原生 macOS CI / 444pt · 合成笔记，非 Monterey 实机" as NSString).draw(at: NSPoint(x: 24, y: 776), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
        for i in 0..<4 {
            let x = CGFloat(24 + (i % 2) * 464), y = CGFloat(i < 2 ? 414 : 32)
            let image = try XCTUnwrap(NSImage(contentsOfFile: dir + "/" + names[i] + ".png"))
            image.draw(in: NSRect(x: x, y: y, width: 444, height: 325))
            (labels[i] as NSString).draw(at: NSPoint(x: x, y: y + 334), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
        }
        sheet.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir + "/contact-sheet.png"))
    }
}
#endif
