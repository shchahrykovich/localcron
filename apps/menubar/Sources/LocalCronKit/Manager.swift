// The manager: a Claude session the user talks to on the Chat page. It is
// the `claude` command the user installed (ClaudeStream.swift), and knows
// LocalCron, the channel's job and its runs, and has the LocalCron MCP
// server, so it can explain a run, change a job or run it again. This file
// is the logic without the process: the conversation as entries, how a line
// from Claude changes them, and what the session is given.

import Foundation

public struct ManagerEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// What the user wrote.
        case user
        /// What the manager answered, Markdown.
        case agent
        /// A tool the manager used; `text` says which.
        case tool
        /// The manager asks to use a tool; `options` are the answers.
        case permission
        /// Something went wrong; `text` says what.
        case error
    }

    public struct Option: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// allow_once, allow_always or reject_once.
        public var kind: String

        public init(id: String, name: String, kind: String) {
            self.id = id
            self.name = name
            self.kind = kind
        }

        public var allows: Bool { kind.hasPrefix("allow") }
    }

    public var id: String
    public var kind: Kind
    public var at: Date
    public var text: String
    /// The run a user message is about.
    public var runID: String?
    /// A tool's state: pending, completed or failed. For a permission
    /// request, the tool's name.
    public var status: String?
    public var options: [Option]
    /// The name of the option the user chose, or "Cancelled".
    public var choice: String?
    /// The files and pictures a user message had; nil in conversations
    /// saved before there were any.
    public var files: [File]?

    /// A file of a user message, as the conversation keeps it: no bytes.
    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var path: String?
        public var image: Bool

        public init(name: String, path: String?, image: Bool) {
            self.name = name
            self.path = path
            self.image = image
        }
    }

    public init(id: String, kind: Kind, at: Date, text: String, runID: String? = nil, status: String? = nil,
                options: [Option] = [], choice: String? = nil, files: [File]? = nil) {
        self.id = id
        self.kind = kind
        self.at = at
        self.text = text
        self.runID = runID
        self.status = status
        self.options = options
        self.choice = choice
        self.files = files
    }

    /// A user message or a manager entry.
    public var fromUser: Bool { kind == .user }
}

/// The conversation of one channel: a job's, or All jobs (`jobID` nil).
public struct ManagerChat: Codable, Equatable, Sendable {
    public var jobID: String?
    /// Claude's session id, so the conversation goes on (`--resume`) after
    /// the app starts again.
    public var sessionID: String?
    public var entries: [ManagerEntry]
    /// Tools the user allowed for the whole conversation.
    public var allowed: [String]?

    public init(jobID: String?, sessionID: String? = nil, entries: [ManagerEntry] = [], allowed: [String]? = nil) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.entries = entries
        self.allowed = allowed
    }

    /// The most entries kept per channel.
    public static let maxEntries = 400
}

public enum Manager {
    /// The key a channel's conversation is saved under.
    public static func key(_ jobID: String?) -> String { jobID ?? "" }

    // MARK: Lines from Claude

    /// Applies one line from Claude to `entries`: the manager's text comes
    /// in pieces, a tool call shows when it starts and its result when it
    /// ends. Lines of a subagent, and other kinds, change nothing.
    public static func apply(_ message: JSON, at: Date, to entries: inout [ManagerEntry]) {
        if let parent = message["parent_tool_use_id"], parent != .null { return }
        switch message["type"]?.string {
        case "stream_event":
            let event = message["event"] ?? .null
            guard event["type"]?.string == "content_block_delta", event["delta"]?["type"]?.string == "text_delta",
                  let text = event["delta"]?["text"]?.string else { return }
            let id = "msg-\(message["api_message_id"]?.string ?? "?")-\(event["index"]?.int ?? 0)"
            if let i = entries.lastIndex(where: { $0.id == id }) {
                entries[i].text += text
            } else {
                entries.append(ManagerEntry(id: id, kind: .agent, at: at, text: text))
            }
        case "assistant":
            for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
                guard let id = block["id"]?.string, let name = block["name"]?.string, !hiddenTools.contains(name),
                      !entries.contains(where: { $0.id == "tool-\(id)" }) else { continue }
                entries.append(ManagerEntry(id: "tool-\(id)", kind: .tool, at: at,
                                            text: toolTitle(name: name, input: block["input"]), status: "pending"))
            }
        case "user":
            for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                guard let id = block["tool_use_id"]?.string,
                      let i = entries.firstIndex(where: { $0.id == "tool-\(id)" }) else { continue }
                entries[i].status = block["is_error"]?.bool == true ? "failed" : "completed"
            }
        default:
            return
        }
    }

    /// Tools Claude Code uses for itself, which say nothing to the user.
    static let hiddenTools: Set<String> = ["ToolSearch"]

    /// `localcron: get_run_log` for `mcp__localcron__get_run_log`, in any text.
    public static func readable(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "mcp__([A-Za-z0-9_-]+?)__([A-Za-z0-9_-]+)") else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1: $2")
    }

    /// What a tool call shows: `localcron: get_run_log`, a shell command's
    /// description, or the file a tool reads.
    public static func toolTitle(name: String, input: JSON?) -> String {
        if name.hasPrefix("mcp__") { return readable(name) }
        if name == "Bash" {
            if let description = input?["description"]?.string, !description.isEmpty { return description }
            if let command = input?["command"]?.string, !command.isEmpty { return "$ " + command }
        }
        if let path = input?["file_path"]?.string ?? input?["path"]?.string, !path.isEmpty {
            return "\(name) \((path as NSString).lastPathComponent)"
        }
        if let pattern = input?["pattern"]?.string, !pattern.isEmpty { return "\(name) \(pattern)" }
        return name
    }

    /// The answers to a permission request. "Always" allows the tool for
    /// the rest of the conversation; the app remembers it, not Claude's
    /// settings files.
    public static func options(for tool: String) -> [ManagerEntry.Option] {
        [.init(id: "allow", name: "Allow", kind: "allow_once"),
         .init(id: "always", name: "Always Allow \(readable(tool)) Here", kind: "allow_always"),
         .init(id: "reject", name: "Reject", kind: "reject_once")]
    }

    /// A `can_use_tool` request as an entry with its answers. `status`
    /// holds the tool's name.
    public static func permission(_ request: JSON, at: Date) -> ManagerEntry {
        let tool = request["tool_name"]?.string ?? "a tool"
        var text = "Use \(toolTitle(name: tool, input: request["input"]))?"
        if let input = request["input"], input != .null, input != .object([:]) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(input), let json = String(data: data, encoding: .utf8) {
                text += "\n```json\n\(String(json.prefix(1500)))\n```"
            }
        }
        return ManagerEntry(id: "ask-\(request["tool_use_id"]?.string ?? UUID().uuidString)", kind: .permission, at: at,
                            text: text, status: tool, options: options(for: tool))
    }

    /// The `control_response` for an answer: allow with the same input, or
    /// deny; nil is a cancel.
    public static func permissionResponse(_ option: ManagerEntry.Option?, input: JSON) -> JSON {
        if let option, option.allows { return ["behavior": "allow", "updatedInput": input] }
        return ["behavior": "deny",
                "message": option == nil ? "The user stopped the answer." : "The user refused this in the LocalCron app."]
    }

    /// Why a turn failed, from its `result` line; nil when it did not.
    public static func failure(_ result: JSON) -> String? {
        let subtype = result["subtype"]?.string ?? "success"
        guard result["is_error"]?.bool == true || subtype != "success" else { return nil }
        if let text = result["result"]?.string, !text.isEmpty { return text }
        if let errors = result["errors"]?.array?.compactMap(\.string), !errors.isEmpty { return errors.joined(separator: "\n") }
        return "Claude stopped: \(subtype.replacingOccurrences(of: "_", with: " "))."
    }

    /// The arguments of `claude` for a channel's session.
    public static func arguments(instructions: String, allowedTools: [String], mcpServer: (name: String, command: String)?,
                                 resume: String?) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    "--append-system-prompt", instructions]
        if !allowedTools.isEmpty { args += ["--allowedTools", allowedTools.joined(separator: ",")] }
        if let mcpServer {
            let config: JSON = ["mcpServers": .object([mcpServer.name: ["command": .string(mcpServer.command), "args": ["mcp"]]])]
            args += ["--mcp-config", String(decoding: config.line(), as: UTF8.self)]
        }
        if let resume { args += ["--resume", resume] }
        return args
    }

    public static func trim(_ entries: inout [ManagerEntry]) {
        if entries.count > ManagerChat.maxEntries { entries.removeFirst(entries.count - ManagerChat.maxEntries) }
    }

    // MARK: What the session is given

    /// The tools the session uses without asking: every tool of the
    /// LocalCron MCP server (`mcp__<server>` allows them all). Other tools
    /// ask the user in the chat first, unless Claude Code's settings allow
    /// them.
    public static func allowedTools(server: String) -> [String] {
        ["mcp__\(server)"]
    }

    /// Added to Claude Code's system prompt for the session of a channel.
    public static func instructions(note: String?, job: Job?, scheduleText: String?, jobIDs: [String],
                                    server: String) -> String {
        var text = """
        # You are the LocalCron manager

        You are in the Chat page of the LocalCron app on the user's Mac. The \
        user writes to you there, between the posts of their scheduled jobs.
        """
        if let job {
            text += " They write in the channel of the job `\(job.id)`: their questions are about this job unless they say otherwise."
        } else {
            text += " They write in the All jobs channel: their questions may be about any job."
        }
        text += """


        Do what the user asks about their LocalCron jobs: explain a run and why it failed, \
        change a job, run it again, add a job, remove one.

        - Use the tools of the MCP server `\(server)`. Read a run's output with \
          `get_run_log`. Read one job with `get_job`: `list_jobs` is long.
        - Change, run, cancel or remove a job only when the user asks for it. The \
          LocalCron tools run without a question to the user, so be sure of what \
          they asked before you call one that changes something.
        - After a change, say in one line what changed.
        - Answer in short Markdown: the app shows it. Name a run by its id.
        - The user's message may start with "[About run …]": that is the run they \
          chose in the app.
        """
        if let job {
            var shown = job
            shown.icon = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(shown), let json = String(data: data, encoding: .utf8) {
                text += "\n\n## The job `\(job.id)` when this conversation started\n\n"
                if let scheduleText { text += "Schedule: \(scheduleText).\n\n" }
                text += "```json\n\(json)\n```\nIt may have changed since: call `get_job` before you change it."
            }
        } else if !jobIDs.isEmpty {
            text += "\n\n## The jobs when this conversation started\n\n" + jobIDs.map { "- `\($0)`" }.joined(separator: "\n")
        }
        if let note, !note.isEmpty {
            text += "\n\n## What LocalCron is (the note agents get)\n\n" + note
        }
        return text
    }

    /// The text sent for one user message: the run it is about, the newest
    /// runs of the channel, then what the user wrote.
    public static func prompt(_ text: String, about run: Run?, recent: [Run], now: Date) -> String {
        var context: [String] = ["[Now: \(ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime]))]"]
        if let run {
            context.append("[About run \(run.id): \(describe(run, now: now))]")
        }
        let others = recent.filter { $0.id != run?.id }.prefix(5)
        if !others.isEmpty {
            context.append("[Newest runs: " + others.map { "\($0.id) \(describe($0, now: now))" }.joined(separator: "; ") + "]")
        }
        return context.joined(separator: "\n") + "\n\n" + text
    }

    private static func describe(_ run: Run, now: Date) -> String {
        var parts = [run.status.rawValue]
        if let started = run.startedAt { parts.append("started \(started)") }
        if let code = run.exitCode { parts.append("exit \(code)") }
        let line = RunText.line(run, now: now).text
        parts.append(String(line.prefix(300)))
        return parts.joined(separator: ", ")
    }
}
