import Foundation
import XCTest
@testable import LocalCronKit

final class SharePromptTests: XCTestCase {
    private let home = "/Users/me"

    private func secret(_ name: String, _ description: String) throws -> SecretInfo {
        let json = #"{"name":"\#(name)","description":"\#(description)","updated_at":"2026-11-01T09:00:00+00:00","state":"ok","set_command":"localcron secret set \#(name)"}"#
        return try JSONDecoder().decode(SecretInfo.self, from: Data(json.utf8))
    }

    /// The JSON block of the prompt, as the agent reads it.
    private func calls(_ prompt: String) throws -> [[String: Any]] {
        let start = try XCTUnwrap(prompt.range(of: "```json\n")).upperBound
        let end = try XCTUnwrap(prompt.range(of: "\n```", range: start..<prompt.endIndex)).lowerBound
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt[start..<end].utf8)) as? [[String: Any]])
    }

    func testAJobBecomesTheFieldsOfAddJobWithTheHomeFolderAsTilde() throws {
        let job = Job(id: "pr-review", schedule: "0 9 * * wed", kind: .claude, prompt: "Review the open pull requests.",
                      model: "opus", permissionMode: "acceptEdits", args: ["--max-turns", "30"], dir: "/Users/me/code/shop",
                      env: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work", "MODE": "/opt/x"], timeoutSecs: 5400,
                      enabled: false, catchUp: false, note: "Weekly", updatedAt: "2026-11-01T09:00:00+00:00")
        let prompt = SharePrompt.text(jobs: [job], secrets: [], home: home)
        let call = try XCTUnwrap(calls(prompt).first)
        XCTAssertEqual(call["id"] as? String, "pr-review")
        XCTAssertEqual(call["schedule"] as? String, "0 9 * * wed")
        XCTAssertEqual(call["kind"] as? String, "claude")
        XCTAssertEqual(call["model"] as? String, "opus")
        XCTAssertEqual(call["permission_mode"] as? String, "acceptEdits")
        XCTAssertEqual(call["args"] as? [String], ["--max-turns", "30"])
        XCTAssertEqual(call["dir"] as? String, "~/code/shop", "the home folder differs on the other Mac")
        XCTAssertEqual(call["env"] as? [String: String], ["CLAUDE_CONFIG_DIR": "~/.claude-work", "MODE": "/opt/x"])
        XCTAssertEqual(call["timeout_minutes"] as? Int, 90, "add_job takes minutes, not timeout_secs")
        XCTAssertEqual(call["enabled"] as? Bool, false)
        XCTAssertEqual(call["catch_up"] as? Bool, false)
        XCTAssertEqual(call["note"] as? String, "Weekly")
        for gone in ["updated_at", "timeout_secs", "command", "secret_env", "icon"] {
            XCTAssertNil(call[gone], gone)
        }
        XCTAssertTrue(prompt.contains("Re-create this LocalCron job"))
        XCTAssertFalse(prompt.contains("list_secrets"), "no secrets, no secret steps")
    }

    func testDefaultsAreLeftOutAndAShellJobHasNoPrompt() throws {
        let job = Job(id: "nightly-tests", schedule: "0 2 * * *", kind: .shell, command: "make test", prompt: "old", dir: "/srv/app")
        let call = try XCTUnwrap(calls(SharePrompt.text(jobs: [job], secrets: [], home: home)).first)
        XCTAssertEqual(Set(call.keys), ["id", "schedule", "kind", "command", "dir"])
        XCTAssertEqual(call["dir"] as? String, "/srv/app", "a folder outside home stays as it is")
    }

    func testSecretsGiveTheirNamesAndDescriptionsNeverAValue() throws {
        let a = Job(id: "a", schedule: "@daily", kind: .shell, command: "gh pr list", dir: home,
                    secretEnv: ["GH_TOKEN": "github-token"])
        let b = Job(id: "b", schedule: "@daily", kind: .codex, prompt: "Sum up", model: "gpt-5", dir: home,
                    secretEnv: ["GH_TOKEN": "github-token", "API_KEY": "openai-key"])
        let prompt = SharePrompt.text(jobs: [a, b], secrets: [try secret("github-token", "GitHub token, repo shop")], home: home)
        XCTAssertTrue(prompt.contains("these 2 LocalCron jobs"))
        XCTAssertTrue(prompt.contains("- `github-token`: GitHub token, repo shop"))
        XCTAssertTrue(prompt.contains("- `openai-key`: no description"), "a secret this Mac does not know")
        XCTAssertTrue(prompt.contains("list_secrets"))
        XCTAssertTrue(prompt.contains("Allow Secrets"))
        XCTAssertTrue(prompt.contains("7. At the end"))
        let all = try calls(prompt)
        XCTAssertEqual(all.map { $0["id"] as? String }, ["a", "b"], "in the order given")
        XCTAssertEqual(all[1]["secret_env"] as? [String: String], ["GH_TOKEN": "github-token", "API_KEY": "openai-key"])
        XCTAssertEqual(all[0]["dir"] as? String, "~")
    }

    func testAnIconGoesWithItsColors() throws {
        let svg = #"<svg viewBox="0 0 16 16"><path d="M0 0h9"/></svg>"#
        let job = Job(id: "x", schedule: "@daily", kind: .shell, command: "true", dir: "/tmp", icon: svg, iconColors: true)
        let call = try XCTUnwrap(calls(SharePrompt.text(jobs: [job], secrets: [], home: home)).first)
        XCTAssertEqual(call["icon"] as? String, svg)
        XCTAssertEqual(call["icon_colors"] as? Bool, true)
    }
}

final class ClaudeConfigDirDraftTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me")

    private func claudeJob(env: [String: String] = [:]) -> Job {
        Job(id: "review", schedule: "@daily", kind: .claude, prompt: "Review", model: "opus", dir: "/Users/me/code", env: env)
    }

    func testNoConfigFolderByDefault() throws {
        var draft = JobDraft(home: home)
        draft.id = "x"
        draft.prompt = "Do it"
        XCTAssertEqual(draft.configDir, "")
        XCTAssertNil(try draft.job().get().env["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(try JobDraft(job: claudeJob(env: ["MODE": "fast"]), home: home).job().get().env, ["MODE": "fast"])
    }

    func testTheConfigFolderBecomesAFullPathInTheEnv() throws {
        var draft = JobDraft(job: claudeJob(env: ["MODE": "fast"]), home: home)
        draft.configDir = " ~/.claude-work "
        XCTAssertEqual(try draft.job().get().env, ["MODE": "fast", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work"],
                       "a variable is not expanded by a shell: no ~ in it")
        draft.configDir = "/Volumes/work/claude"
        XCTAssertEqual(try draft.job().get().env["CLAUDE_CONFIG_DIR"], "/Volumes/work/claude")
        draft.configDir = ".claude-work"
        guard case let .failure(error) = draft.job() else { return XCTFail("a relative folder is refused") }
        XCTAssertTrue(error.message.contains("full path"))
    }

    func testASavedConfigFolderShowsWithTildeAndCanBeCleared() throws {
        var draft = JobDraft(job: claudeJob(env: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work"]), home: home)
        XCTAssertEqual(draft.configDir, "~/.claude-work")
        XCTAssertEqual(try draft.job().get().env["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-work", "unchanged")
        draft.configDir = ""
        XCTAssertNil(try draft.job().get().env["CLAUDE_CONFIG_DIR"])
    }

    func testOtherKindsKeepTheirEnvAsItIs() throws {
        // A shell job may run claude itself, with the variable set by an agent.
        let shell = Job(id: "s", schedule: "@daily", kind: .shell, command: "claude -p hi", dir: "/tmp",
                        env: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work"])
        let draft = JobDraft(job: shell, home: home)
        XCTAssertEqual(draft.configDir, "", "the field is for claude jobs")
        XCTAssertEqual(try draft.job().get().env, shell.env)
    }
}
