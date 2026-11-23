// A conversation with the `claude` command the user installed, the same one
// claude jobs run: `claude -p --input-format stream-json --output-format
// stream-json`. Each line on stdin and stdout is one JSON object. The user's
// message goes in as {"type":"user",...}; Claude's answer comes out in
// pieces ("stream_event", "assistant", "user" with tool results) and ends
// with {"type":"result"}. With `--permission-prompt-tool stdio`, Claude asks
// before a tool as {"type":"control_request","request":{"subtype":
// "can_use_tool",...}}, and waits for a "control_response".
//
// `ClaudeSession` does not know the process: it writes lines with `write`
// and is given each line Claude prints with `receive(line:)`.
// `ClaudeProcess` joins the two; tests join it to a script.

import Foundation

/// Any JSON value.
public enum JSON: Equatable, Sendable, Codable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSON? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case let .string(s) = self { return s } else { return nil } }
    public var array: [JSON]? { if case let .array(a) = self { return a } else { return nil } }
    public var bool: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    public var int: Int? { if case let .number(n) = self { return Int(exactly: n.rounded()) } else { return nil } }

    /// One line of JSON, without a line break in it.
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public static func parse(_ data: Data) -> JSON? { try? JSONDecoder().decode(JSON.self, from: data) }
}

public struct ClaudeError: Error, LocalizedError, Equatable, Sendable {
    public var message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

public final class ClaudeSession: @unchecked Sendable {
    /// Every line Claude prints but the end of a turn: its text, tool calls
    /// and results, and its questions (`control_request`).
    public var onMessage: (@Sendable (JSON) -> Void)?

    private let write: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var turn: CheckedContinuation<JSON, Error>?
    private var closedReason: String?
    private var sessionID: String?

    public init(write: @escaping @Sendable (Data) -> Void) {
        self.write = write
    }

    /// The session id Claude gave in its first line; nil before it.
    public var id: String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedReason != nil
    }

    /// Sends a message and waits until Claude has answered: the `result`
    /// line, which has the session id, the cost and whether it failed.
    public func send(_ text: String) async throws -> JSON {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<JSON, Error>) in
            lock.lock()
            if let closedReason {
                lock.unlock()
                done.resume(throwing: ClaudeError(closedReason))
                return
            }
            if turn != nil {
                lock.unlock()
                done.resume(throwing: ClaudeError("Claude is still answering the last message."))
                return
            }
            turn = done
            lock.unlock()
            send(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": .string(text)]]]])
        }
    }

    /// The answer to a `control_request`.
    public func respond(to requestID: String, _ response: JSON) {
        send(["type": "control_response",
              "response": ["subtype": "success", "request_id": .string(requestID), "response": response]])
    }

    /// Stops the answer Claude works on; `send` then returns its result.
    public func interrupt() {
        send(["type": "control_request", "request_id": .string(UUID().uuidString), "request": ["subtype": "interrupt"]])
    }

    /// One line Claude printed. A line that is not JSON is ignored.
    public func receive(line: Data) {
        guard let message = JSON.parse(line) else { return }
        if let id = message["session_id"]?.string {
            lock.lock()
            sessionID = id
            lock.unlock()
        }
        switch message["type"]?.string {
        case "result":
            lock.lock()
            let done = turn
            turn = nil
            lock.unlock()
            done?.resume(returning: message)
        case "control_response":
            return
        default:
            onMessage?(message)
        }
    }

    /// Claude is gone: the turn that waits fails with `why`, and so does
    /// every later one.
    public func close(_ why: String) {
        lock.lock()
        if closedReason == nil { closedReason = why }
        let done = turn
        turn = nil
        lock.unlock()
        done?.resume(throwing: ClaudeError(why))
    }

    private func send(_ message: JSON) {
        var data = message.line()
        data.append(0x0A)
        write(data)
    }
}

/// Splits bytes into lines. Output comes in pieces of any size.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex ..< end]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex ... end)
        }
        return lines
    }
}

/// A `claude` process with a `ClaudeSession` on its stdin and stdout.
public final class ClaudeProcess: @unchecked Sendable {
    public let session: ClaudeSession
    private let process: Process
    private let input: FileHandle

    /// Starts `executable` with `arguments` in `directory`. `onExit` is
    /// called once, after the session is closed.
    public init(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                onExit: (@Sendable () -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let writer = input.fileHandleForWriting
        let session = ClaudeSession { data in
            try? writer.write(contentsOf: data)
        }
        self.session = session
        self.process = process
        self.input = writer
        let tail = Tail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.add(data) }
        }
        let reader = output.fileHandleForReading
        try process.run()
        // Reads every line, then closes the session when the output ends:
        // the last lines come before the reason it stopped.
        Thread.detachNewThread {
            var lines = LineBuffer()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                for line in lines.append(data) { session.receive(line: line) }
            }
            process.waitUntilExit()
            let text = tail.text
            session.close(text.isEmpty ? "Claude stopped (exit code \(process.terminationStatus))." : "Claude stopped: \(text)")
            onExit?()
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// Ends the conversation: Claude stops when its input ends.
    public func stop() {
        try? input.close()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
    }

    /// The last 2000 bytes of stderr, for an error message.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func add(_ more: Data) {
            lock.lock()
            data.append(more)
            if data.count > 2000 { data = data.suffix(2000) }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
