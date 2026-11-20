#if os(macOS)
import XCTest
import JotportCore
@testable import Jotport

final class TerminalFocusTests: XCTestCase {
    func reference() -> TerminalRef {
        var ref = TerminalRef(path: "/WezTerm.app", identity: "test", version: "test")
        ref.processID = 42
        ref.paneID = "17"
        ref.socketPath = "/tmp/gui-sock-42"
        return ref
    }

    func testTwoPanesSelectRecordedPaneAndVerifyIt() throws {
        var calls: [[String]] = []
        try TerminalFocus.focusWezTerm(reference(), sockets: "p42\nn/tmp/gui-sock-42\n") { args, env in
            calls.append(args)
            XCTAssertEqual(env["WEZTERM_UNIX_SOCKET"], "/tmp/gui-sock-42")
            XCTAssertNil(env["WEZTERM_PANE"])
            if args.contains("activate-pane") { return "" }
            return "[{\"pane_id\":3,\"is_active\":true},{\"pane_id\":17,\"is_active\":\(calls.count == 3)}]"
        }
        XCTAssertEqual(calls, [["cli", "--no-auto-start", "list", "--format", "json"],
                               ["cli", "--no-auto-start", "activate-pane", "--pane-id", "17"],
                               ["cli", "--no-auto-start", "list", "--format", "json"]])
    }

    func testLegacyAndWrongInstanceNeverIssueCommands() {
        var legacy = reference(); legacy.paneID = nil
        for (ref, sockets) in [(legacy, "n/tmp/gui-sock-42"), (reference(), "n/tmp/gui-sock-99")] {
            XCTAssertThrowsError(try TerminalFocus.focusWezTerm(ref, sockets: sockets) { _, _ in
                XCTFail("No command without exact identity"); return ""
            })
        }
    }

    func testMissingPaneUnsupportedCLIAndUnconfirmedSelectionFail() {
        for json in ["[]", "unsupported", "[{\"pane_id\":17,\"is_active\":false}]"] {
            var activated = 0
            XCTAssertThrowsError(try TerminalFocus.focusWezTerm(reference(), sockets: "n/tmp/gui-sock-42") { args, _ in
                if args.contains("activate-pane") { activated += 1; return "" }
                return json
            })
            XCTAssertEqual(activated, json.contains("17") ? 1 : 0)
        }
        XCTAssertThrowsError(try TerminalFocus.focusWezTerm(reference(), sockets: "n/tmp/gui-sock-42") { _, _ in
            throw LaunchFailure(message: "连接超时")
        })
    }
}
#endif
