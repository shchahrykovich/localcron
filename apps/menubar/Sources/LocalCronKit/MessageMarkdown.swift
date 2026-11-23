import AppKit
import SwiftUI

/// A message's Markdown as blocks the Chat page draws one by one: headings,
/// paragraphs, list items, quotes, code blocks, tables and rules. Apple's
/// parser reads the Markdown; this only groups its text by block.
public enum MessageMarkdown {
    public struct Block: Equatable, Identifiable, Sendable {
        public enum Kind: Equatable, Sendable {
            case paragraph
            case heading(Int)
            case code(language: String?)
            case rule
            case table(Table)
        }

        public var id: Int
        public var kind: Kind
        /// The inline text, with links, bold, italic and code; for a code
        /// block its lines, without the last line break.
        public var text: AttributedString
        /// Set when the block is in a list item.
        public var list: ListPosition?
        /// How many quotes the block is in.
        public var quoteDepth: Int
    }

    public struct ListPosition: Equatable, Sendable {
        /// "•", or "2." in a numbered list; "" for a second paragraph of the
        /// same item.
        public var marker: String
        /// 1 for a top list, 2 for a list in it.
        public var depth: Int

        public init(marker: String, depth: Int) {
            self.marker = marker
            self.depth = depth
        }
    }

    public struct Table: Equatable, Sendable {
        public var header: [AttributedString]
        public var rows: [[AttributedString]]
    }

    /// The blocks of `text`, in order. Text the parser refuses is one
    /// paragraph, as it is.
    public static func blocks(_ text: String) -> [Block] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [Block(id: 0, kind: .paragraph, text: AttributedString(text), list: nil, quoteDepth: 0)]
        }
        var blocks: [Block] = []
        var blockID: Int?
        var tableRow: Int?
        var lastCell: Int?
        var itemsSeen: Set<Int> = []
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            if let inline = run.inlinePresentationIntent, inline.contains(.softBreak) || inline.contains(.lineBreak) {
                piece = AttributedString("\n")
            }
            let parts = run.presentationIntent?.components ?? []
            if let table = parts.first(where: { if case .table = $0.kind { true } else { false } }) {
                let row = parts.first { if case .tableRow = $0.kind { true } else if case .tableHeaderRow = $0.kind { true } else { false } }
                let header = parts.contains { if case .tableHeaderRow = $0.kind { true } else { false } }
                let cell = parts.first { if case .tableCell = $0.kind { true } else { false } }
                if blockID != table.identity {
                    blocks.append(Block(id: table.identity, kind: .table(Table(header: [], rows: [])), text: "", list: nil,
                                        quoteDepth: quoteDepth(parts)))
                    blockID = table.identity
                    tableRow = nil
                    lastCell = nil
                }
                guard case var .table(t) = blocks[blocks.count - 1].kind else { continue }
                if let cell, cell.identity == lastCell {
                    // Several runs of one cell (bold, a link) make one cell.
                    if header { t.header[t.header.count - 1].append(piece) } else { t.rows[t.rows.count - 1][t.rows[t.rows.count - 1].count - 1].append(piece) }
                } else if header {
                    t.header.append(piece)
                } else if row?.identity != tableRow {
                    t.rows.append([piece])
                    tableRow = row?.identity
                } else {
                    t.rows[t.rows.count - 1].append(piece)
                }
                lastCell = cell?.identity
                blocks[blocks.count - 1].kind = .table(t)
                continue
            }
            lastCell = nil
            let inner = parts.first
            if let inner, inner.identity == blockID {
                blocks[blocks.count - 1].text.append(piece)
                continue
            }
            blockID = inner?.identity
            var kind = Block.Kind.paragraph
            switch inner?.kind {
            case let .header(level): kind = .heading(level)
            case let .codeBlock(language): kind = .code(language: language.flatMap { $0.isEmpty ? nil : $0 })
            case .thematicBreak: kind = .rule; piece = ""
            default: break
            }
            blocks.append(Block(id: inner?.identity ?? -(blocks.count + 1), kind: kind, text: piece,
                                list: listPosition(parts, seen: &itemsSeen), quoteDepth: quoteDepth(parts)))
        }
        for i in blocks.indices {
            if case .code = blocks[i].kind, blocks[i].text.characters.last == "\n" {
                blocks[i].text.removeSubrange(blocks[i].text.index(beforeCharacter: blocks[i].text.endIndex)...)
            }
        }
        return blocks
    }

    private static func quoteDepth(_ parts: [PresentationIntent.IntentType]) -> Int {
        parts.filter { if case .blockQuote = $0.kind { true } else { false } }.count
    }

    /// Where the block is in lists. `parts` is innermost first: the list
    /// item, then its list, then outer items and lists.
    private static func listPosition(_ parts: [PresentationIntent.IntentType], seen: inout Set<Int>) -> ListPosition? {
        let depth = parts.filter { if case .orderedList = $0.kind { true } else if case .unorderedList = $0.kind { true } else { false } }.count
        guard depth > 0, let i = parts.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
              case let .listItem(ordinal) = parts[i].kind else { return nil }
        let ordered = parts.indices.contains(i + 1) && { if case .orderedList = parts[i + 1].kind { true } else { false } }()
        let first = seen.insert(parts[i].identity).inserted
        return ListPosition(marker: first ? (ordered ? "\(ordinal)." : "•") : "", depth: depth)
    }

    /// The color behind the words a search found.
    public static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.45)

    /// Inline text for a text view: fonts for bold, italic and code, a
    /// pointing hand on links, and `highlight` marked wherever it is, in any
    /// case.
    public static func attributed(_ text: AttributedString, size: CGFloat, weight: NSFont.Weight = .regular,
                                  monospaced: Bool = false, color: NSColor = .labelColor,
                                  highlight: String = "") -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        for run in text.runs {
            let inline = run.inlinePresentationIntent ?? []
            let code = monospaced || inline.contains(.code)
            var font = code ? NSFont.monospacedSystemFont(ofSize: size - 0.5, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: inline.contains(.stronglyEmphasized) ? .bold : weight)
            var traits = font.fontDescriptor.symbolicTraits
            if inline.contains(.emphasized) { traits.insert(.italic) }
            if code && inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if traits != font.fontDescriptor.symbolicTraits {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if inline.contains(.code), !monospaced { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.07) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.cursor] = NSCursor.pointingHand
            }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        for range in matches(of: highlight, in: out.string) {
            out.addAttribute(.backgroundColor, value: highlightColor, range: range)
        }
        return out
    }

    /// Where `query` (trimmed, in any case) is in `text`.
    public static func matches(of query: String, in text: String) -> [NSRange] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let text = text as NSString
        var found: [NSRange] = []
        var from = 0
        while from < text.length {
            let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: from, length: text.length - from))
            if range.location == NSNotFound { break }
            found.append(range)
            from = range.location + max(range.length, 1)
        }
        return found
    }
}

/// Text in an AppKit text view: it can be selected, opens links with a
/// click and shows the pointing hand over them, which SwiftUI's `Text`
/// cannot on macOS 14. It wraps to the width it is given.
public struct LinkText: NSViewRepresentable {
    let text: NSAttributedString
    let linkColor: NSColor

    public init(_ text: NSAttributedString, linkColor: NSColor) {
        self.text = text
        self.linkColor = linkColor
    }

    public func makeNSView(context: Context) -> NSTextView {
        let view = Self.makeTextView(linkColor: linkColor)
        view.textStorage?.setAttributedString(text)
        return view
    }

    public func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.isEqual(to: text) == false { view.textStorage?.setAttributedString(text) }
        view.linkTextAttributes = Self.linkAttributes(linkColor)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 100_000
        return Self.size(of: nsView, width: width)
    }

    static func linkAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: color, .cursor: NSCursor.pointingHand]
    }

    /// A text view that shows text: not editable, no background, no inset;
    /// TextKit 1, so it can be measured before it is drawn.
    @MainActor
    static func makeTextView(linkColor: NSColor) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = linkAttributes(linkColor)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    /// The size of the text wrapped at `width`: its own width when shorter.
    @MainActor
    static func size(of view: NSTextView, width: CGFloat) -> CGSize {
        guard let container = view.textContainer, let layout = view.layoutManager else { return .zero }
        let tracks = container.widthTracksTextView
        container.widthTracksTextView = false
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        container.widthTracksTextView = tracks
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }
}

/// A message's Markdown, block by block, for the Chat page.
public struct MessageBody: View {
    public struct Colors {
        public var link: NSColor
        /// The box behind a code block and the lines of a table.
        public var box: Color
        public var line: Color

        public init(link: NSColor, box: Color, line: Color) {
            self.link = link
            self.box = box
            self.line = line
        }
    }

    let blocks: [MessageMarkdown.Block]
    let colors: Colors
    var size: CGFloat = 13
    var highlight = ""

    public init(_ text: String, colors: Colors, size: CGFloat = 13, highlight: String = "") {
        blocks = MessageMarkdown.blocks(text)
        self.colors = colors
        self.size = size
        self.highlight = highlight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                quoted(block.quoteDepth) { listed(block.list) { content(block) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ block: MessageMarkdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            text(block.text)
        case let .heading(level):
            text(block.text, size: level == 1 ? size + 4 : level == 2 ? size + 2 : size, weight: level <= 2 ? .bold : .semibold)
                .padding(.top, 2)
        case .code:
            text(block.text, size: size - 1, monospaced: true)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.box, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Rectangle().fill(colors.line).frame(height: 1).padding(.vertical, 4)
        case let .table(table):
            tableView(table)
        }
    }

    private func text(_ inline: AttributedString, size: CGFloat? = nil, weight: NSFont.Weight = .regular,
                      monospaced: Bool = false) -> some View {
        LinkText(MessageMarkdown.attributed(inline, size: size ?? self.size, weight: weight, monospaced: monospaced,
                                            highlight: highlight),
                 linkColor: colors.link)
    }

    @ViewBuilder private func listed(_ list: MessageMarkdown.ListPosition?, @ViewBuilder _ content: () -> some View) -> some View {
        if let list {
            // .top: the text view gives SwiftUI no baseline; both start
            // their first line at the top.
            HStack(alignment: .top, spacing: 6) {
                Text(list.marker).font(.system(size: size).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                content()
            }
            .padding(.leading, CGFloat(list.depth - 1) * 18)
        } else {
            content()
        }
    }

    @ViewBuilder private func quoted(_ depth: Int, @ViewBuilder _ content: () -> some View) -> some View {
        if depth > 0 {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<depth, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(colors.line).frame(width: 3)
                }
                content().opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            content()
        }
    }

    private func tableView(_ table: MessageMarkdown.Table) -> some View {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        func cells(_ row: [AttributedString], bold: Bool) -> some View {
            GridRow {
                ForEach(0..<columns, id: \.self) { i in
                    text(i < row.count ? row[i] : "", weight: bold ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !table.header.isEmpty {
                cells(table.header, bold: true)
                Rectangle().fill(colors.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Rectangle().fill(colors.line.opacity(0.5)).frame(height: 0.5).gridCellUnsizedAxes(.horizontal) }
                cells(row, bold: false)
            }
        }
        .background(colors.box.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(colors.line, lineWidth: 0.5))
    }
}
