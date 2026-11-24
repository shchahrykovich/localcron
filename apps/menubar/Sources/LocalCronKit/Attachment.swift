// Files and pictures the user adds to a message for the manager: pasted
// (⌘V) or dropped on the box. A picture goes to Claude as an image block of
// the message; any other file goes as its path, which the session can read.

import Foundation

/// One file or picture in the composer, before it is sent.
public struct Attachment: Equatable, Identifiable, Sendable {
    public var id: String
    /// What the chip shows: the file's name, or "Pasted image.png".
    public var name: String
    /// The file on disk; a pasted picture is saved to a temporary file.
    public var path: String?
    /// image/png, image/jpeg, image/gif or image/webp; nil for any other file.
    public var mediaType: String?
    /// The picture's bytes, for an image.
    public var data: Data?

    public init(id: String = UUID().uuidString, name: String, path: String? = nil, mediaType: String? = nil, data: Data? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.mediaType = mediaType
        self.data = data
    }

    public var isImage: Bool { mediaType != nil && data != nil }

    /// What the saved conversation keeps of it: no bytes.
    public var saved: ManagerEntry.File { ManagerEntry.File(name: name, path: path, image: isImage) }
}

public enum Attachments {
    /// The largest picture sent as it is. Claude takes up to 5 MB per image
    /// once in base64, which is 4/3 of the bytes; a larger one is made
    /// smaller first.
    public static let maxImageBytes = 3_700_000
    /// The most files in one message.
    public static let maxCount = 10

    /// The media type Claude reads for a picture with this file extension,
    /// or nil when it is not a picture Claude reads.
    public static func mediaType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }

    /// The media type from the first bytes of a picture, or nil.
    public static func mediaType(sniffing data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(b[8 ..< 12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }

    /// The text Claude gets: the user's text, then one line per file that is
    /// not a picture, with its path.
    public static func text(_ text: String, files: [Attachment]) -> String {
        let lines = files.filter { !$0.isImage }.compactMap { file in file.path.map { "Attached file: \($0)" } }
        guard !lines.isEmpty else { return text }
        return text.isEmpty ? lines.joined(separator: "\n") : text + "\n\n" + lines.joined(separator: "\n")
    }

    /// The `content` of a stream-json user message: the pictures as base64
    /// image blocks, then the text.
    public static func content(_ text: String, files: [Attachment]) -> JSON {
        var blocks: [JSON] = files.filter(\.isImage).map { file in
            ["type": "image",
             "source": ["type": "base64", "media_type": .string(file.mediaType ?? "image/png"),
                        "data": .string(file.data?.base64EncodedString() ?? "")]]
        }
        let all = Self.text(text, files: files)
        if !all.isEmpty || blocks.isEmpty { blocks.append(["type": "text", "text": .string(all)]) }
        return .array(blocks)
    }
}
