import Foundation

/// A prompt for a coding agent on another Mac that re-creates jobs there with
/// the `add_job` tool. It holds what each job runs and the names of its
/// secrets, never a secret's value (the app does not have them).
public enum SharePrompt {
    /// The fields of `add_job` (apps/cli/src/mcp.rs `AddJobArgs`), with the
    /// defaults left out so the prompt stays short.
    struct AddJob: Encodable, Equatable {
        var id: String
        var schedule: String
        var kind: String
        var prompt: String?
        var command: String?
        var dir: String
        var model: String?
        var permissionMode: String?
        var args: [String]?
        var env: [String: String]?
        var secretEnv: [String: String]?
        var timeoutMinutes: UInt64?
        var catchUp: Bool?
        var enabled: Bool?
        var note: String?
        var icon: String?
        var iconColors: Bool?

        enum CodingKeys: String, CodingKey {
            case id, schedule, kind, prompt, command, dir, model, args, env, enabled, note, icon
            case permissionMode = "permission_mode"
            case secretEnv = "secret_env"
            case timeoutMinutes = "timeout_minutes"
            case catchUp = "catch_up"
            case iconColors = "icon_colors"
        }

        init(_ job: Job, home: String) {
            id = job.id
            schedule = job.schedule
            kind = job.kind.rawValue
            prompt = job.kind == .shell ? nil : job.prompt
            command = job.kind == .shell ? job.command : nil
            dir = JobGroups.tilde(job.dir, home: home)
            model = job.model
            permissionMode = job.permissionMode
            args = job.args.isEmpty ? nil : job.args
            env = job.env.isEmpty ? nil : job.env.mapValues { JobGroups.tilde($0, home: home) }
            secretEnv = job.secretEnv.isEmpty ? nil : job.secretEnv
            // add_job takes minutes; round up so a run never gets less time.
            timeoutMinutes = job.timeoutSecs == Job.defaultTimeout ? nil : (job.timeoutSecs + 59) / 60
            catchUp = job.catchUp ? nil : false
            enabled = job.enabled ? nil : false
            note = job.note.isEmpty ? nil : job.note
            icon = job.icon?.isEmpty == false ? job.icon : nil
            iconColors = job.iconColors && icon != nil ? true : nil
        }
    }

    /// The prompt for `jobs`. `secrets` gives the descriptions of the secrets
    /// they name; `home` is this Mac's home folder.
    public static func text(jobs: [Job], secrets: [SecretInfo], home: String = NSHomeDirectory(),
                            appName: String = "LocalCron") -> String {
        let calls = jobs.map { AddJob($0, home: home) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(calls)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let one = jobs.count == 1
        let what = one ? "this \(appName) job" : "these \(jobs.count) \(appName) jobs"
        var lines = [
            "Re-create \(what) on this Mac. \(one ? "It comes" : "They come") from my other Mac.",
            "",
            "Use the `add_job` tool of the \(appName) MCP server, once per job, with the fields in the JSON below. "
                + "When the \(appName) tools are missing, stop and tell me to install \(appName) and choose "
                + "Coding Agents, Add to Claude Code (or Add to Codex) in its menu.",
            "",
            "1. `~` in `dir` and in `env` values is the home folder. Write the full path of this Mac's home folder "
                + "instead: a job does not expand `~`. When a `dir` does not exist here, ask me where that project is. "
                + "Do not create the folder.",
            "2. Check that what each job runs exists here: the programs in a shell `command`, and `claude` or `codex` for an agent job. Tell me what is missing.",
            "3. A schedule `@at` with a time in the past: ask me for a new time.",
            "4. A job id that exists here already: ask me before you change it with `replace: true`.",
        ]
        let names = Set(jobs.flatMap(\.secretEnv.values))
        if !names.isEmpty {
            lines += [
                "5. `secret_env` holds names of secrets, not their values. Call `list_secrets`. For each secret that is "
                    + "missing here, give me its `set_command` to run in my own terminal, with the description below. "
                    + "Never ask me for a value in this chat.",
                "6. A job with secrets runs only after I allow it in the \(appName) menu bar app (Jobs, Allow Secrets). "
                    + "Tell me which jobs wait for that.",
            ]
        }
        lines.append("\(names.isEmpty ? 5 : 7). At the end, list each job: its id, the schedule in words and the next run.")

        if !names.isEmpty {
            let described = Dictionary(secrets.map { ($0.name, $0.description) }, uniquingKeysWith: { a, _ in a })
            lines += ["", "Secrets the jobs use, and how to make a new value:"]
            for name in names.sorted() {
                let description = described[name].map { $0.isEmpty ? "no description" : $0 } ?? "no description"
                lines.append("- `\(name)`: \(description)")
            }
        }

        lines += ["", "Jobs:", "", "```json", json, "```"]
        return lines.joined(separator: "\n")
    }
}
