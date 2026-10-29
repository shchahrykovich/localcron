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
    /// `secret_env` as rows the form can edit: variable and secret name.
    public var secretRows: [SecretEnvRow]

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
        secretRows = []
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
        secretRows = job.secretEnv.sorted { $0.key < $1.key }.map { SecretEnvRow(variable: $0.key, secret: $0.value) }
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
        var secretEnv: [String: String] = [:]
        for row in secretRows {
            let variable = trimmed(row.variable), secret = trimmed(row.secret)
            switch (variable, secret) {
            case (nil, nil):
                continue
            case let (v?, s?):
                if secretEnv[v] != nil {
                    return .failure(ApiError(code: "invalid", message: "\(v) is in Secrets twice."))
                }
                secretEnv[v] = s
            case let (v?, nil):
                return .failure(ApiError(code: "invalid", message: "Choose a secret for \(v)."))
            case (nil, _):
                return .failure(ApiError(code: "invalid", message: "Give the variable name for each secret, like GH_TOKEN."))
            }
        }
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

/// One line of a job's secrets: the variable the run gets, and the secret
/// that gives its value.
public struct SecretEnvRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var variable: String
    public var secret: String

    public init(variable: String = "", secret: String = "") {
        id = UUID()
        self.variable = variable
        self.secret = secret
    }
}

/// The secret editor's fields. The value goes to the daemon, which keeps it
/// in the Keychain; the app never stores it.
public struct SecretDraft: Equatable, Sendable {
    /// False when editing: the name cannot change, and an empty value keeps
    /// the old one.
    public var isNew: Bool
    public var name: String
    public var description: String
    public var value: String

    public init() {
        isNew = true
        name = ""
        description = ""
        value = ""
    }

    public init(secret: SecretInfo) {
        isNew = false
        name = secret.name
        description = secret.description
        value = ""
    }

    /// The request, or why the form is not complete.
    public func params() -> Result<SetSecretParams, ApiError> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(ApiError(code: "invalid", message: "Give the secret a name, like github-token.")) }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // A value is used as typed: spaces can be part of it. A pasted line
        // end is not.
        let value = value.trimmingCharacters(in: .newlines)
        if isNew && value.isEmpty { return .failure(ApiError(code: "invalid", message: "Paste or type the value.")) }
        return .success(SetSecretParams(name: name, value: value.isEmpty ? nil : value, description: description))
    }
}
