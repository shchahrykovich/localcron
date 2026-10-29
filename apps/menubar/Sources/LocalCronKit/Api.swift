// Swift copy of the socket API shapes in libs/core/src/api.rs, job.rs and
// run.rs. Every file in api/examples must decode here and in Rust.
//
// Keys are written out in CodingKeys, not converted by a key strategy: a
// strategy would also change the keys of `env` ("REVIEW_LIMIT").
// Times stay strings, as the daemon sends them; `ApiDate` reads them.

import Foundation

public let apiVersion = "1.2"

public func apiMajor(_ version: String) -> Int? {
    version.split(separator: ".").first.flatMap { Int($0) }
}

public enum Api {
    public static let decoder = JSONDecoder()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

/// RFC 3339 times from the daemon: `2026-10-28T11:02:55Z` or
/// `2026-10-28T12:02:55+01:00`, with or without fractions of a second.
public enum ApiDate {
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let lock = NSLock()

    public static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}

// MARK: - Envelope

public struct ApiError: Codable, Error, Equatable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var errorDescription: String? { message }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct Empty: Codable, Equatable, Sendable {
    public init() {}
}

public struct HelloParams: Codable, Equatable, Sendable {
    public var client: String
    public var apiVersion: String

    public init(client: String, apiVersion: String) {
        self.client = client
        self.apiVersion = apiVersion
    }

    enum CodingKeys: String, CodingKey {
        case client
        case apiVersion = "api_version"
    }
}

public struct HelloResult: Codable, Equatable, Sendable {
    public var daemonVersion: String
    public var apiVersion: String

    enum CodingKeys: String, CodingKey {
        case daemonVersion = "daemon_version"
        case apiVersion = "api_version"
    }
}

// MARK: - Jobs

public enum JobKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case shell, claude, codex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shell: "Shell"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public struct Job: Codable, Equatable, Sendable, Identifiable {
    public static let defaultTimeout: UInt64 = 3600

    /// a-z, 0-9 and '-': `weekly-deps-check`.
    public var id: String
    /// A cron expression or `@at YYYY-MM-DD HH:MM`, in local time.
    public var schedule: String
    public var kind: JobKind
    public var command: String?
    public var prompt: String?
    public var model: String?
    public var permissionMode: String?
    public var args: [String]
    public var dir: String
    public var env: [String: String]
    /// Variable name to secret name. The daemon reads the value from the
    /// Keychain when the run starts.
    public var secretEnv: [String: String]
    public var timeoutSecs: UInt64
    public var enabled: Bool
    public var catchUp: Bool
    public var note: String
    /// Set by the daemon.
    public var updatedAt: String?

    public init(id: String, schedule: String, kind: JobKind, command: String? = nil, prompt: String? = nil,
                model: String? = nil, permissionMode: String? = nil, args: [String] = [], dir: String,
                env: [String: String] = [:], secretEnv: [String: String] = [:], timeoutSecs: UInt64 = Job.defaultTimeout,
                enabled: Bool = true, catchUp: Bool = true, note: String = "", updatedAt: String? = nil) {
        self.id = id
        self.schedule = schedule
        self.kind = kind
        self.command = command
        self.prompt = prompt
        self.model = model
        self.permissionMode = permissionMode
        self.args = args
        self.dir = dir
        self.env = env
        self.secretEnv = secretEnv
        self.timeoutSecs = timeoutSecs
        self.enabled = enabled
        self.catchUp = catchUp
        self.note = note
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, schedule, kind, command, prompt, model, args, dir, env, enabled, note
        case permissionMode = "permission_mode"
        case secretEnv = "secret_env"
        case timeoutSecs = "timeout_secs"
        case catchUp = "catch_up"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        schedule = try c.decode(String.self, forKey: .schedule)
        kind = try c.decode(JobKind.self, forKey: .kind)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        dir = try c.decode(String.self, forKey: .dir)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        secretEnv = try c.decodeIfPresent([String: String].self, forKey: .secretEnv) ?? [:]
        timeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .timeoutSecs) ?? Self.defaultTimeout
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        catchUp = try c.decodeIfPresent(Bool.self, forKey: .catchUp) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    // Same omissions as the Rust side, so a round trip gives the same JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(permissionMode, forKey: .permissionMode)
        if !args.isEmpty { try c.encode(args, forKey: .args) }
        try c.encode(dir, forKey: .dir)
        if !env.isEmpty { try c.encode(env, forKey: .env) }
        if !secretEnv.isEmpty { try c.encode(secretEnv, forKey: .secretEnv) }
        try c.encode(timeoutSecs, forKey: .timeoutSecs)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(catchUp, forKey: .catchUp)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

/// A job with what the daemon knows about it. The job's fields are
/// flattened into the same object.
public struct JobView: Codable, Equatable, Sendable, Identifiable {
    public var job: Job
    /// "At 09:00 on Wednesday".
    public var scheduleText: String
    public var nextRun: String?
    /// The newest finished run.
    public var lastRun: Run?
    /// A run that is queued or running now.
    public var activeRun: Run?

    public var id: String { job.id }

    enum CodingKeys: String, CodingKey {
        case scheduleText = "schedule_text"
        case nextRun = "next_run"
        case lastRun = "last_run"
        case activeRun = "active_run"
    }

    public init(from decoder: Decoder) throws {
        job = try Job(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduleText = try c.decode(String.self, forKey: .scheduleText)
        nextRun = try c.decodeIfPresent(String.self, forKey: .nextRun)
        lastRun = try c.decodeIfPresent(Run.self, forKey: .lastRun)
        activeRun = try c.decodeIfPresent(Run.self, forKey: .activeRun)
    }

    public func encode(to encoder: Encoder) throws {
        try job.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scheduleText, forKey: .scheduleText)
        try c.encodeIfPresent(nextRun, forKey: .nextRun)
        try c.encodeIfPresent(lastRun, forKey: .lastRun)
        try c.encodeIfPresent(activeRun, forKey: .activeRun)
    }
}

// MARK: - Runs

public enum Trigger: String, Codable, Sendable {
    case schedule
    case catchUp = "catch_up"
    case manual

    public var title: String {
        switch self {
        case .schedule: "Schedule"
        case .catchUp: "Catch-up"
        case .manual: "Manual"
        }
    }
}

public enum RunStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed, canceled, skipped
    case timedOut = "timed_out"

    public var isFinished: Bool { self != .queued && self != .running }

    /// The run went wrong: the menu bar icon shows a warning.
    public var isFailure: Bool { self == .failed || self == .timedOut }

    public var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .timedOut: "Timed out"
        case .canceled: "Canceled"
        case .skipped: "Skipped"
        }
    }
}

public struct Run: Codable, Equatable, Sendable, Identifiable {
    /// `<job id>.<number>`.
    public var id: String
    public var jobId: String
    public var trigger: Trigger
    public var status: RunStatus
    public var dueAt: String?
    public var queuedAt: String
    public var startedAt: String?
    public var endedAt: String?
    public var exitCode: Int32?
    public var pid: UInt32?
    /// Absolute path of the output file.
    public var log: String?
    public var message: String

    enum CodingKeys: String, CodingKey {
        case id, trigger, status, pid, log, message
        case jobId = "job_id"
        case dueAt = "due_at"
        case queuedAt = "queued_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case exitCode = "exit_code"
    }

    public init(id: String, jobId: String, trigger: Trigger, status: RunStatus, dueAt: String? = nil, queuedAt: String,
                startedAt: String? = nil, endedAt: String? = nil, exitCode: Int32? = nil, pid: UInt32? = nil,
                log: String? = nil, message: String = "") {
        self.id = id
        self.jobId = jobId
        self.trigger = trigger
        self.status = status
        self.dueAt = dueAt
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.pid = pid
        self.log = log
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        jobId = try c.decode(String.self, forKey: .jobId)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        status = try c.decode(RunStatus.self, forKey: .status)
        dueAt = try c.decodeIfPresent(String.self, forKey: .dueAt)
        queuedAt = try c.decode(String.self, forKey: .queuedAt)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        pid = try c.decodeIfPresent(UInt32.self, forKey: .pid)
        log = try c.decodeIfPresent(String.self, forKey: .log)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(jobId, forKey: .jobId)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(dueAt, forKey: .dueAt)
        try c.encode(queuedAt, forKey: .queuedAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(log, forKey: .log)
        if !message.isEmpty { try c.encode(message, forKey: .message) }
    }
}

// MARK: - Status and config

public struct NextRun: Codable, Equatable, Sendable {
    public var jobId: String
    public var at: String

    enum CodingKeys: String, CodingKey {
        case at
        case jobId = "job_id"
    }
}

public struct StatusResult: Codable, Equatable, Sendable {
    public var daemonVersion: String
    public var apiVersion: String
    public var pid: UInt32
    public var startedAt: String
    public var jobs: Int
    public var enabledJobs: Int
    public var running: Int
    public var queued: Int
    public var maxConcurrent: UInt32
    /// Scheduled runs do not start.
    public var paused: Bool
    public var next: NextRun?
    public var dataDir: String
    public var logsDir: String

    enum CodingKeys: String, CodingKey {
        case pid, jobs, running, queued, paused, next
        case daemonVersion = "daemon_version"
        case apiVersion = "api_version"
        case startedAt = "started_at"
        case enabledJobs = "enabled_jobs"
        case maxConcurrent = "max_concurrent"
        case dataDir = "data_dir"
        case logsDir = "logs_dir"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemonVersion = try c.decode(String.self, forKey: .daemonVersion)
        apiVersion = try c.decode(String.self, forKey: .apiVersion)
        pid = try c.decode(UInt32.self, forKey: .pid)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        jobs = try c.decode(Int.self, forKey: .jobs)
        enabledJobs = try c.decode(Int.self, forKey: .enabledJobs)
        running = try c.decode(Int.self, forKey: .running)
        queued = try c.decode(Int.self, forKey: .queued)
        maxConcurrent = try c.decode(UInt32.self, forKey: .maxConcurrent)
        // A 1.0 daemon does not send it.
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        next = try c.decodeIfPresent(NextRun.self, forKey: .next)
        dataDir = try c.decode(String.self, forKey: .dataDir)
        logsDir = try c.decode(String.self, forKey: .logsDir)
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var maxConcurrent: UInt32
    public var keepRuns: UInt32
    /// No scheduled run starts; a run someone asks for still does.
    public var paused: Bool
    /// The last resume. Times before it are not caught up.
    public var resumedAt: String?

    public init(maxConcurrent: UInt32, keepRuns: UInt32, paused: Bool = false, resumedAt: String? = nil) {
        self.maxConcurrent = maxConcurrent
        self.keepRuns = keepRuns
        self.paused = paused
        self.resumedAt = resumedAt
    }

    enum CodingKeys: String, CodingKey {
        case paused
        case maxConcurrent = "max_concurrent"
        case keepRuns = "keep_runs"
        case resumedAt = "resumed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrent = try c.decode(UInt32.self, forKey: .maxConcurrent)
        keepRuns = try c.decode(UInt32.self, forKey: .keepRuns)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        resumedAt = try c.decodeIfPresent(String.self, forKey: .resumedAt)
    }
}

public struct SetConfigParams: Codable, Equatable, Sendable {
    public var maxConcurrent: UInt32?
    public var keepRuns: UInt32?
    /// Pause (true) or resume (false) every schedule.
    public var paused: Bool?

    public init(maxConcurrent: UInt32? = nil, keepRuns: UInt32? = nil, paused: Bool? = nil) {
        self.maxConcurrent = maxConcurrent
        self.keepRuns = keepRuns
        self.paused = paused
    }

    enum CodingKeys: String, CodingKey {
        case paused
        case maxConcurrent = "max_concurrent"
        case keepRuns = "keep_runs"
    }
}

// MARK: - Params and results

public struct ListJobsResult: Codable, Equatable, Sendable {
    public var jobs: [JobView]
}

public struct IdParams: Codable, Equatable, Sendable {
    public var id: String

    public init(id: String) { self.id = id }
}

public struct SetJobParams: Codable, Equatable, Sendable {
    public var job: Job
    /// Without it an existing id is an error.
    public var replace: Bool

    public init(job: Job, replace: Bool) {
        self.job = job
        self.replace = replace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = try c.decode(Job.self, forKey: .job)
        replace = try c.decodeIfPresent(Bool.self, forKey: .replace) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case job, replace
    }
}

public struct SetJobResult: Codable, Equatable, Sendable {
    public var job: JobView
    public var created: Bool
    /// Secrets in `secret_env` that are not set yet: runs fail until the
    /// user sets them.
    public var missingSecrets: [MissingSecret]

    enum CodingKeys: String, CodingKey {
        case job, created
        case missingSecrets = "missing_secrets"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = try c.decode(JobView.self, forKey: .job)
        created = try c.decode(Bool.self, forKey: .created)
        missingSecrets = try c.decodeIfPresent([MissingSecret].self, forKey: .missingSecrets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(job, forKey: .job)
        try c.encode(created, forKey: .created)
        if !missingSecrets.isEmpty { try c.encode(missingSecrets, forKey: .missingSecrets) }
    }
}

public struct MissingSecret: Codable, Equatable, Sendable {
    public var name: String
    /// The variable in `secret_env` that wants it.
    public var env: String
    /// For the user to run in a terminal: `localcron secret set github-token`.
    public var setCommand: String

    enum CodingKeys: String, CodingKey {
        case name, env
        case setCommand = "set_command"
    }
}

public struct JobResult: Codable, Equatable, Sendable {
    public var job: JobView
}

public struct RemoveJobResult: Codable, Equatable, Sendable {
    public var removed: Bool
}

public struct SetJobEnabledParams: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool

    public init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

public struct RunResult: Codable, Equatable, Sendable {
    public var run: Run
}

public struct CancelRunParams: Codable, Equatable, Sendable {
    public var runId: String
    /// SIGKILL now, also for a run that is already stopping.
    public var force: Bool

    public init(runId: String, force: Bool = false) {
        self.runId = runId
        self.force = force
    }

    enum CodingKeys: String, CodingKey {
        case force
        case runId = "run_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runId, forKey: .runId)
        if force { try c.encode(force, forKey: .force) }
    }
}

public struct CancelRunResult: Codable, Equatable, Sendable {
    /// False when the run had already finished, or was already being
    /// stopped (killed, with `force`).
    public var canceled: Bool
    public var run: Run
}

public struct ListRunsParams: Codable, Equatable, Sendable {
    public var jobId: String?
    public var limit: Int?

    public init(jobId: String? = nil, limit: Int? = nil) {
        self.jobId = jobId
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case limit
        case jobId = "job_id"
    }
}

public struct ListRunsResult: Codable, Equatable, Sendable {
    public var runs: [Run]
}

public struct GetRunLogParams: Codable, Equatable, Sendable {
    public var runId: String
    public var maxBytes: UInt64?

    public init(runId: String, maxBytes: UInt64? = nil) {
        self.runId = runId
        self.maxBytes = maxBytes
    }

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case maxBytes = "max_bytes"
    }
}

public struct GetRunLogResult: Codable, Equatable, Sendable {
    public var run: Run
    public var text: String
    /// The file is longer than `text`: only its end is here.
    public var truncated: Bool
    public var size: UInt64
}

public struct PreviewScheduleParams: Codable, Equatable, Sendable {
    public var schedule: String
    public var count: Int?

    public init(schedule: String, count: Int? = nil) {
        self.schedule = schedule
        self.count = count
    }
}

public struct PreviewScheduleResult: Codable, Equatable, Sendable {
    public var description: String
    public var next: [String]
}

// MARK: - Secrets

public enum SecretState: String, Codable, Sendable {
    /// The daemon can read the value.
    case ok
    /// No value in the Keychain.
    case missing
    /// The Keychain needs a dialog to give the value.
    case unreadable
}

/// A secret without its value. No reply has the value.
public struct SecretInfo: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    /// How to get a new value: where, which scopes, the expiry.
    public var description: String
    public var updatedAt: String
    public var state: SecretState
    /// Why the state is not ok.
    public var message: String
    /// The jobs that name it in `secret_env`.
    public var usedBy: [String]
    /// For the user to run in a terminal to set a new value.
    public var setCommand: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, description, state, message
        case updatedAt = "updated_at"
        case usedBy = "used_by"
        case setCommand = "set_command"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        state = try c.decode(SecretState.self, forKey: .state)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        usedBy = try c.decodeIfPresent([String].self, forKey: .usedBy) ?? []
        setCommand = try c.decode(String.self, forKey: .setCommand)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !description.isEmpty { try c.encode(description, forKey: .description) }
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(state, forKey: .state)
        if !message.isEmpty { try c.encode(message, forKey: .message) }
        if !usedBy.isEmpty { try c.encode(usedBy, forKey: .usedBy) }
        try c.encode(setCommand, forKey: .setCommand)
    }
}

public struct ListSecretsResult: Codable, Equatable, Sendable {
    public var secrets: [SecretInfo]
}

/// Without `value` only the description changes. The value goes to the
/// daemon, which stores it in the Keychain; it is never in a reply.
public struct SetSecretParams: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    public var name: String
    public var value: String?
    public var description: String?

    public init(name: String, value: String? = nil, description: String? = nil) {
        self.name = name
        self.value = value
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name, value, description
    }

    // Used by print and string interpolation too (the type has no
    // CustomStringConvertible: `description` is a field). Never the value.
    public var debugDescription: String { "SetSecretParams(name: \(name), value: \(value == nil ? "nil" : "<hidden>"))" }
}

public struct SetSecretResult: Codable, Equatable, Sendable {
    public var secret: SecretInfo
    public var created: Bool
}

public struct NameParams: Codable, Equatable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct RemoveSecretResult: Codable, Equatable, Sendable {
    public var removed: Bool
    /// Jobs that still name it.
    public var usedBy: [String]

    enum CodingKeys: String, CodingKey {
        case removed
        case usedBy = "used_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removed = try c.decode(Bool.self, forKey: .removed)
        usedBy = try c.decodeIfPresent([String].self, forKey: .usedBy) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(removed, forKey: .removed)
        if !usedBy.isEmpty { try c.encode(usedBy, forKey: .usedBy) }
    }
}
