import AppKit
import LocalCronKit
import Observation

/// The conversations with the manager on the Chat page (Manager.swift). Each
/// channel has its own `claude` process, the one the user installed, started
/// when the user writes and stopped after `idleStop` without a message. The
/// conversations are saved in the app's data folder with Claude's session
/// ids, so a channel goes on with the same session (`--resume`) after the
/// app or its process starts again.
@MainActor
@Observable
final class ManagerStore {
    private(set) var chats: [String: ManagerChat] = [:]
    /// Channels whose session works on an answer now.
    private(set) var working: Set<String> = []
    /// What the composer holds, per channel: its text and the run it is about.
    var drafts: [String: String] = [:]
    var aboutRun: [String: String] = [:]
    /// Goes up when the composer should take the keyboard: after "Ask the
    /// manager about this run".
    var focusRequest = 0

    /// A process with nothing to do stops after this; the next message
    /// starts it again with the same session.
    static let idleStop: TimeInterval = 15 * 60

    private var processes: [String: ClaudeProcess] = [:]
    private var idle: [String: Task<Void, Never>] = [:]
    /// A permission request that waits for the user, by entry id.
    private var asks: [String: (key: String, request: String, input: JSON)] = [:]
    @ObservationIgnored private let file: URL

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(Instance.current.dataFolder).appendingPathComponent("manager-chats.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: ManagerChat].self, from: data) {
            chats = saved
        }
    }

    func entries(_ jobID: String?) -> [ManagerEntry] { chats[Manager.key(jobID)]?.entries ?? [] }
    func isWorking(_ jobID: String?) -> Bool { working.contains(Manager.key(jobID)) }
    func isWaiting(_ entry: ManagerEntry) -> Bool { asks[entry.id] != nil }

    // MARK: What the user does

    func send(_ text: String, jobID: String?, model: AppModel) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Manager.key(jobID)
        guard !text.isEmpty, !working.contains(key) else { return }
        let runID = aboutRun[key]
        let run = runID.flatMap { id in model.allRuns.first { $0.id == id } }
        append(ManagerEntry(id: "user-\(UUID().uuidString)", kind: .user, at: Date(), text: text, runID: runID), to: key)
        drafts[key] = nil
        aboutRun[key] = nil
        working.insert(key)
        idle[key]?.cancel()
        save()
        let recent = model.allRuns.filter { jobID == nil || $0.jobId == jobID }
            .sorted { ($0.shownAt ?? .distantPast) > ($1.shownAt ?? .distantPast) }
        let prompt = Manager.prompt(text, about: run, recent: recent, now: Date())
        Task {
            do {
                let result = try await self.turn(prompt, key: key, jobID: jobID, model: model)
                if let failure = Manager.failure(result) { self.addError(failure, to: key) }
            } catch {
                self.addError(error.localizedDescription, to: key)
            }
            self.working.remove(key)
            self.save()
            self.stopWhenIdle(key)
        }
    }

    /// The user's answer to a permission request; nil cancels it.
    func answer(_ entry: ManagerEntry, with option: ManagerEntry.Option?) {
        guard let ask = asks.removeValue(forKey: entry.id) else { return }
        processes[ask.key]?.session.respond(to: ask.request, Manager.permissionResponse(option, input: ask.input))
        update(entry.id, in: ask.key) { $0.choice = option?.name ?? "Cancelled" }
        if option?.kind == "allow_always", let tool = entry.status {
            chats[ask.key]?.allowed = Array(Set((chats[ask.key]?.allowed ?? []) + [tool])).sorted()
        }
        save()
    }

    /// Stops the answer the manager works on.
    func stop(jobID: String?) {
        let key = Manager.key(jobID)
        cancelAsks(of: key)
        processes[key]?.session.interrupt()
    }

    /// Forgets the conversation: the next message starts a new session.
    func startOver(jobID: String?) {
        let key = Manager.key(jobID)
        cancelAsks(of: key)
        processes.removeValue(forKey: key)?.stop()
        chats[key] = nil
        working.remove(key)
        save()
    }

    // MARK: Claude

    /// Sends one message, starting the channel's process when it has none.
    /// A saved session that Claude cannot open again is replaced by a new one.
    private func turn(_ prompt: String, key: String, jobID: String?, model: AppModel) async throws -> JSON {
        if let process = processes[key], process.isRunning, !process.session.isClosed {
            return try await process.session.send(prompt)
        }
        let saved = chats[key]?.sessionID
        do {
            return try await start(key, jobID: jobID, model: model, resume: saved).session.send(prompt)
        } catch where saved != nil {
            addError("The earlier conversation could not be opened again (\(error.localizedDescription)); this is a new one.",
                     to: key)
            chats[key]?.sessionID = nil
            return try await start(key, jobID: jobID, model: model, resume: nil).session.send(prompt)
        }
    }

    private func start(_ key: String, jobID: String?, model: AppModel, resume: String?) async throws -> ClaudeProcess {
        let (claude, path) = try await Self.findClaude()
        let fm = FileManager.default
        let job = jobID.flatMap(model.job)
        var isDir: ObjCBool = false
        let dir = job.map(\.job.dir).flatMap { fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil }
            ?? fm.homeDirectoryForCurrentUser.path
        let bundle = Bundle.main.bundleURL
        let note = try? String(contentsOf: bundle.appendingPathComponent(BundleLayout.claudeNote), encoding: .utf8)
        let server = Instance.current.cli
        let cli = bundle.appendingPathComponent(BundleLayout.cli).path
        let instructions = Manager.instructions(note: note, job: job?.job, scheduleText: job?.scheduleText,
                                                jobIDs: model.jobs.map(\.id), server: server)
        let arguments = Manager.arguments(
            instructions: instructions,
            allowedTools: Manager.readOnlyTools(server: server) + (chats[key]?.allowed ?? []),
            mcpServer: fm.isExecutableFile(atPath: cli) ? (server, cli) : nil,
            resume: resume)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        let process = try ClaudeProcess(executable: claude, arguments: arguments, directory: URL(fileURLWithPath: dir),
                                        environment: environment) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ended(key) }
            }
        }
        process.session.onMessage = { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(message, key: key) }
            }
        }
        processes[key]?.stop()
        processes[key] = process
        return process
    }

    /// `claude` and the PATH of the user's login shell, as claude jobs find it.
    private nonisolated static func findClaude() async throws -> (URL, String) {
        let output = await Task.detached {
            LoginShellRunner(timeout: 30).run(["/bin/sh", "-c", "command -v claude; printf 'PATH=%s\\n' \"$PATH\""])
        }.value
        let lines = output.output.components(separatedBy: "\n")
        let path = lines.last { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) } ?? "/usr/bin:/bin"
        guard let found = lines.last(where: { $0.hasPrefix("/") && $0.hasSuffix("/claude") }) else {
            throw ClaudeError("The manager is Claude Code, and the `claude` command is not on your login shell's PATH. Install Claude Code, then write again.")
        }
        return (URL(fileURLWithPath: found), path)
    }

    private func received(_ message: JSON, key: String) {
        if let id = message["session_id"]?.string, chats[key]?.sessionID != id {
            var chat = chats[key] ?? ManagerChat(jobID: key.isEmpty ? nil : key)
            chat.sessionID = id
            chats[key] = chat
        }
        if message["type"]?.string == "control_request" {
            asked(message, key: key)
            return
        }
        var entries = chats[key]?.entries ?? []
        let before = entries
        Manager.apply(message, at: Date(), to: &entries)
        guard entries != before else { return }
        Manager.trim(&entries)
        chats[key]?.entries = entries
    }

    private func asked(_ message: JSON, key: String) {
        guard let requestID = message["request_id"]?.string else { return }
        let request = message["request"] ?? .null
        guard request["subtype"]?.string == "can_use_tool" else {
            // Nothing else is asked of a host with this setup; say no
            // rather than leave Claude waiting.
            processes[key]?.session.respond(to: requestID, ["behavior": "deny", "message": "LocalCron cannot answer this."])
            return
        }
        let input = request["input"] ?? .object([:])
        let entry = Manager.permission(request, at: Date())
        asks[entry.id] = (key, requestID, input)
        append(entry, to: key)
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func ended(_ key: String) {
        if processes[key]?.isRunning == false { processes[key] = nil }
        cancelAsks(of: key, answer: false)
    }

    private func cancelAsks(of key: String, answer: Bool = true) {
        for (id, ask) in asks where ask.key == key {
            if answer, let entry = chats[key]?.entries.first(where: { $0.id == id }) {
                self.answer(entry, with: nil)
            } else {
                asks[id] = nil
                update(id, in: key) { $0.choice = "Cancelled" }
            }
        }
    }

    private func stopWhenIdle(_ key: String) {
        idle[key]?.cancel()
        idle[key] = Task {
            try? await Task.sleep(for: .seconds(Self.idleStop))
            guard !Task.isCancelled, !working.contains(key) else { return }
            processes.removeValue(forKey: key)?.stop()
        }
    }

    // MARK: Entries

    private func addError(_ text: String, to key: String) {
        append(ManagerEntry(id: "error-\(UUID().uuidString)", kind: .error, at: Date(), text: text), to: key)
    }

    private func append(_ entry: ManagerEntry, to key: String) {
        var chat = chats[key] ?? ManagerChat(jobID: key.isEmpty ? nil : key)
        chat.entries.append(entry)
        Manager.trim(&chat.entries)
        chats[key] = chat
    }

    private func update(_ id: String, in key: String, _ change: (inout ManagerEntry) -> Void) {
        guard let i = chats[key]?.entries.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[key]!.entries[i])
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(chats).write(to: file, options: .atomic)
        } catch {
            NSLog("LocalCron: cannot save the manager chats: \(error.localizedDescription)")
        }
    }
}
