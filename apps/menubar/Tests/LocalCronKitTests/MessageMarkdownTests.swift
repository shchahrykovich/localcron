import AppKit
import SwiftUI
import XCTest
@testable import LocalCronKit

final class MessageMarkdownTests: XCTestCase {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    func testEachKindOfBlock() {
        let blocks = MessageMarkdown.blocks("""
        ## Deals today
        Acquire: 18 seen
        - one **bold**
          - nested
        2. two
        > a quote
        ```sh
        ls -la
        ```
        ---
        end
        """)
        XCTAssertEqual(blocks.map(\.kind), [.heading(2), .paragraph, .paragraph, .paragraph, .paragraph, .paragraph,
                                            .code(language: "sh"), .rule, .paragraph])
        XCTAssertEqual(blocks.map { plain($0.text) }, ["Deals today", "Acquire: 18 seen", "one bold", "nested", "two",
                                                       "a quote", "ls -la", "", "end"])
        XCTAssertEqual(blocks.map(\.list), [nil, nil, .init(marker: "•", depth: 1), .init(marker: "•", depth: 2),
                                            .init(marker: "2.", depth: 1), nil, nil, nil, nil])
        XCTAssertEqual(blocks.map(\.quoteDepth), [0, 0, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count, "ids are unique")
    }

    /// A second paragraph of one list item has no marker of its own.
    func testASecondParagraphOfAListItemHasNoMarker() {
        let blocks = MessageMarkdown.blocks("- first\n\n  more of first\n- second")
        XCTAssertEqual(blocks.map { plain($0.text) }, ["first", "more of first", "second"])
        XCTAssertEqual(blocks.map { $0.list?.marker }, ["•", "", "•"])
    }

    func testATableKeepsItsHeaderRowsAndLinks() throws {
        let blocks = MessageMarkdown.blocks("| Deal | Ask |\n|---|---|\n| [98611](https://e.com/98611) | 122,969 |\n| 97635 | 241,871 |")
        XCTAssertEqual(blocks.count, 1)
        guard case let .table(table) = blocks[0].kind else { return XCTFail("not a table: \(blocks[0].kind)") }
        XCTAssertEqual(table.header.map(plain), ["Deal", "Ask"])
        XCTAssertEqual(table.rows.map { $0.map(plain) }, [["98611", "122,969"], ["97635", "241,871"]])
        XCTAssertEqual(table.rows[0][0].runs.first?.link, URL(string: "https://e.com/98611"))
    }

    /// Agents write one line per fact; a line break stays a line break, as
    /// in a chat, not a space as in strict Markdown.
    func testLineBreaksInAParagraphStay() {
        let blocks = MessageMarkdown.blocks("Acquire: 18 seen\nEmpire Flippers: 36 seen")
        XCTAssertEqual(blocks.map { plain($0.text) }, ["Acquire: 18 seen\nEmpire Flippers: 36 seen"])
    }

    func testBareUrlsAndMarkdownLinksAreLinks() {
        let text = MessageMarkdown.blocks("see https://app.acquire.com/startup/ib9 ; and [the list](https://e.com/l).")[0].text
        let links = text.runs.compactMap { run in run.link.map { (plain(AttributedString(text[run.range])), $0.absoluteString) } }
        XCTAssertEqual(links.map(\.0), ["https://app.acquire.com/startup/ib9", "the list"])
        XCTAssertEqual(links.map(\.1), ["https://app.acquire.com/startup/ib9", "https://e.com/l"])
    }

    func testTextThatIsNotMarkdownStaysText() {
        XCTAssertEqual(MessageMarkdown.blocks("a [b").map { plain($0.text) }, ["a [b"])
        XCTAssertEqual(MessageMarkdown.blocks("plain words").map(\.kind), [.paragraph])
        XCTAssertEqual(MessageMarkdown.blocks("  ").count, 0)
    }

    func testBoldItalicCodeAndLinksBecomeFontsAndAPointingHand() throws {
        let inline = MessageMarkdown.blocks("**bold** *italic* `code` [link](https://e.com) ~~gone~~")[0].text
        let out = MessageMarkdown.attributed(inline, size: 13)
        func attrs(_ word: String) -> [NSAttributedString.Key: Any] {
            let range = (out.string as NSString).range(of: word)
            return out.attributes(at: range.location, effectiveRange: nil)
        }
        let traits = { (word: String) in (attrs(word)[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? [] }
        XCTAssertTrue(traits("bold").contains(.bold))
        XCTAssertTrue(traits("italic").contains(.italic))
        XCTAssertTrue(traits("code").contains(.monoSpace))
        XCTAssertNotNil(attrs("code")[.backgroundColor])
        XCTAssertEqual(attrs("link")[.link] as? URL, URL(string: "https://e.com"))
        XCTAssertEqual(attrs("link")[.cursor] as? NSCursor, NSCursor.pointingHand)
        XCTAssertNil(attrs("bold")[.cursor], "plain text keeps the text cursor")
        XCTAssertEqual(attrs("gone")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual((attrs("bold")[.font] as? NSFont)?.pointSize, 13)
    }

    @MainActor
    func testTheTextViewShowsAPointingHandOnLinksAndWrapsToTheWidth() throws {
        let view = LinkText.makeTextView(linkColor: .systemBlue)
        XCTAssertEqual(view.linkTextAttributes?[.cursor] as? NSCursor, NSCursor.pointingHand)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        let words = String(repeating: "word ", count: 60)
        view.textStorage?.setAttributedString(MessageMarkdown.attributed(AttributedString(words), size: 13))
        let wide = LinkText.size(of: view, width: 2000)
        let narrow = LinkText.size(of: view, width: 200)
        XCTAssertLessThanOrEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.height, wide.height * 3, "it wraps into more lines")
        XCTAssertLessThan(wide.width, 2000, "a short text takes its own width, not all it may")
    }

    func testASearchMarksEachPlaceInAnyCase() {
        XCTAssertEqual(MessageMarkdown.matches(of: " full ", in: "Disk FULL, still full"), [NSRange(location: 5, length: 4),
                                                                                             NSRange(location: 17, length: 4)])
        XCTAssertEqual(MessageMarkdown.matches(of: "", in: "abc"), [])
        let out = MessageMarkdown.attributed(AttributedString("the disk is full"), size: 13, highlight: "DISK")
        XCTAssertEqual(out.attribute(.backgroundColor, at: 4, effectiveRange: nil) as? NSColor, MessageMarkdown.highlightColor)
        XCTAssertNil(out.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }
}
