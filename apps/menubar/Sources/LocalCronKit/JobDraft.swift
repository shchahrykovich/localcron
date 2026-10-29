// The job editor's fields. Text fields hold strings; `job()` turns them
// into a Job for set_job. The daemon checks the job again and says what is
// wrong; this only catches what the form can tell by itself.

import Foundation

public struct JobDraft: Equatable, Sendable {
    /// False when editing: the id cannot change, and set_job replaces.
    public var isNew: Bool
    public var id: String
    public var schedule: String
    public var kind: JobKind
    public var command: String
    public var prompt: String
    public var model: String
    public var permissionMode: String
    public var argsText: String
    public var dir: String
    public var timeoutMinutes: Int
    public var enabled: Bool
    public var catchUp: Bool
    public var note: String
    /// Kept as it was: the form does not edit it.
    public var env: [String: String]
    /// Kept as it was: the form does not edit it.
    public var secretEnv: [String: String]

    /// A new Claude job on weekday mornings in the home folder.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        isNew = true
        id = ""
        schedule = "0 9 * * mon-fri"
        kind = .claude
        command = ""
        prompt = ""
        model = ""
        permissionMode = ""
        argsText = ""
        dir = home.path
        timeoutMinutes = 60
        enabled = true
        catchUp = true
        note = ""
        env = [:]
        secretEnv = [:]
    }

    public init(job: Job) {
        isNew = false
        id = job.id
        schedule = job.schedule
        kind = job.kind
        command = job.command ?? ""
        prompt = job.prompt ?? ""
        model = job.model ?? ""
        permissionMode = job.permissionMode ?? ""
        argsText = Formatting.joinArgs(job.args)
        dir = job.dir
        timeoutMinutes = max(1, Int((Double(job.timeoutSecs) / 60).rounded(.up)))
        enabled = job.enabled
        catchUp = job.catchUp
        note = job.note
        env = job.env
        secretEnv = job.secretEnv
    }

    /// Permission modes `claude --permission-mode` takes. Empty uses the
    /// user's Claude Code settings.
    public static let permissionModes = ["", "default", "acceptEdits", "plan", "bypassPermissions"]

    private func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The job, or why the form is not complete.
    public func job() -> Result<Job, ApiError> {
        guard let id = trimmed(id) else { return .failure(ApiError(code: "invalid", message: "Give the job an id, like weekly-review.")) }
        guard let schedule = trimmed(schedule) else { return .failure(ApiError(code: "invalid", message: "Give a schedule.")) }
        let agent = kind != .shell
        if agent, trimmed(prompt) == nil { return .failure(ApiError(code: "invalid", message: "Write the prompt.")) }
        if !agent, trimmed(command) == nil { return .failure(ApiError(code: "invalid", message: "Write the command.")) }
        return .success(Job(
            id: id,
            schedule: schedule,
            kind: kind,
            command: agent ? nil : trimmed(command),
            prompt: agent ? trimmed(prompt) : nil,
            model: agent ? trimmed(model) : nil,
            permissionMode: kind == .claude ? trimmed(permissionMode) : nil,
            args: agent ? Formatting.splitArgs(argsText) : [],
            dir: trimmed(dir) ?? "",
            env: env,
            secretEnv: secretEnv,
            timeoutSecs: UInt64(max(1, timeoutMinutes)) * 60,
            enabled: enabled,
            catchUp: catchUp,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
