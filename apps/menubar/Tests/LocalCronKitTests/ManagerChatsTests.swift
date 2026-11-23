import Foundation
import XCTest
@testable import LocalCronKit

@MainActor
final class ManagerChatsTests: XCTestCase {
    private let t0 = ApiDate.parse("2026-11-23T12:00:00Z")!

    /// "Always Allow … Here" on a permission card. Version 0.16.0 stopped
    /// the app here with "Simultaneous accesses": it read the chats while it
    /// wrote them.
    func testAllowingAToolForTheConversationKeepsItOnce() {
        let chats = ManagerChats()
        chats.append(ManagerEntry(id: "u1", kind: .user, at: t0, text: "hi"), to: "deps")
        chats.allow("mcp__localcron__run_job", in: "deps")
        chats.allow("mcp__localcron__enable_job", in: "deps")
        chats.allow("mcp__localcron__run_job", in: "deps")
        XCTAssertEqual(chats.allowed("deps"), ["mcp__localcron__enable_job", "mcp__localcron__run_job"])
        XCTAssertEqual(chats.allowed("other"), [])
    }

    func testEntriesSessionsAndUpdates() {
        let chats = ManagerChats()
        chats.setSession("s1", in: "")
        chats.append(ManagerEntry(id: "u1", kind: .user, at: t0, text: "hi"), to: "")
        chats.apply(["type": "stream_event", "api_message_id": "m1",
                     "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hello"]]],
                    at: t0, in: "")
        chats.update("u1", in: "") { $0.text = "hi there" }
        XCTAssertEqual(chats.sessionID(""), "s1")
        XCTAssertEqual(chats.entries("").map(\.text), ["hi there", "Hello"])
        XCTAssertNil(chats.chats[""]?.jobID, "the key \"\" is All jobs")
        chats.remove("")
        XCTAssertEqual(chats.entries(""), [])
    }
}
