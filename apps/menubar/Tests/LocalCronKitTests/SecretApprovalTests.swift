import Foundation
import XCTest
@testable import LocalCronKit

/// The approval dialog: a short text above, the whole job in a scrolling
/// field below. A long prompt in the alert's own text made the window taller
/// than the screen and hid its buttons.
final class SecretApprovalTests: XCTestCase {
    private let longPrompt = String(repeating: "Do one more careful step of the work. ", count: 200)

    private func job() -> Job {
        Job(id: "weekly-article", schedule: "30 14 * * thu", kind: .claude, prompt: longPrompt, model: "sonnet",
            permissionMode: "bypassPermissions", args: ["--max-turns", "80"], dir: "/Users/me/Projects/writer",
            env: ["MODE": "fast"], secretEnv: ["OPENROUTER_API_KEY": "openrouter", "DATA_FOR_SEO_API_KEY": "dataforseo"])
    }

    func testTheShortTextHasNoPromptAndNamesTheSecrets() {
        let text = SecretApproval(job: job()).summary
        XCTAssertLessThan(text.count, 500, text)
        XCTAssertFalse(text.contains("careful step"), "the prompt belongs in the scrolling field")
        XCTAssertTrue(text.contains("DATA_FOR_SEO_API_KEY from dataforseo, OPENROUTER_API_KEY from openrouter"), text)
        XCTAssertTrue(text.contains("~/Projects/writer") || text.contains("/Users/me/Projects/writer"), text)
    }

    func testTheFieldShowsEverythingTheApprovalCovers() {
        let details = SecretApproval(job: job()).details
        XCTAssertTrue(details.contains(longPrompt), "the whole prompt, not cut")
        for part in ["Claude prompt", "--max-turns 80", "Model: sonnet", "Permission mode: bypassPermissions", "MODE=fast",
                     "OPENROUTER_API_KEY from openrouter"] {
            XCTAssertTrue(details.contains(part), "\(part) is missing:\n\(details.prefix(300))")
        }
    }

    func testAShellJobShowsItsCommand() {
        let shell = Job(id: "deploy", schedule: "@daily", kind: .shell, command: "./deploy.sh --prod", dir: "/tmp",
                        secretEnv: ["GH_TOKEN": "github-token"])
        let approval = SecretApproval(job: shell)
        XCTAssertTrue(approval.details.hasPrefix("Command:\n./deploy.sh --prod"), approval.details)
        XCTAssertEqual(approval.title, "Allow deploy to read its secrets?")
    }
}
