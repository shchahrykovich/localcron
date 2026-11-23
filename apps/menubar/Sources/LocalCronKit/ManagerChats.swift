import Foundation
import Observation

/// The conversations with the manager, by channel key (`Manager.key`), and
/// every change to them. `ManagerStore` in the app owns one and runs the
/// processes; this part has no process, so tests can drive it.
@MainActor
@Observable
public final class ManagerChats {
    public private(set) var chats: [String: ManagerChat]

    public init(_ chats: [String: ManagerChat] = [:]) {
        self.chats = chats
    }

    public func entries(_ key: String) -> [ManagerEntry] { chats[key]?.entries ?? [] }
    public func sessionID(_ key: String) -> String? { chats[key]?.sessionID }
    public func allowed(_ key: String) -> [String] { chats[key]?.allowed ?? [] }

    public func append(_ entry: ManagerEntry, to key: String) {
        var chat = chats[key] ?? ManagerChat(jobID: key.isEmpty ? nil : key)
        chat.entries.append(entry)
        Manager.trim(&chat.entries)
        chats[key] = chat
    }

    public func update(_ id: String, in key: String, _ change: (inout ManagerEntry) -> Void) {
        guard let i = chats[key]?.entries.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[key]!.entries[i])
    }

    /// The user allowed `tool` for the rest of the conversation. The list is
    /// read before the write: `chats[key]?.allowed = … chats …` reads the
    /// property while it writes it, which Swift stops at run time.
    public func allow(_ tool: String, in key: String) {
        guard var chat = chats[key] else { return }
        chat.allowed = Array(Set((chat.allowed ?? []) + [tool])).sorted()
        chats[key] = chat
    }

    public func setSession(_ id: String?, in key: String) {
        var chat = chats[key] ?? ManagerChat(jobID: key.isEmpty ? nil : key)
        chat.sessionID = id
        chats[key] = chat
    }

    /// Applies one line from Claude; see `Manager.apply`.
    public func apply(_ message: JSON, at: Date, in key: String) {
        var entries = chats[key]?.entries ?? []
        let before = entries
        Manager.apply(message, at: at, to: &entries)
        guard entries != before else { return }
        Manager.trim(&entries)
        chats[key]?.entries = entries
    }

    public func remove(_ key: String) {
        chats[key] = nil
    }
}
