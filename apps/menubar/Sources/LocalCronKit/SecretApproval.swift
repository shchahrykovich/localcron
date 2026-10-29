// The text of the dialog where the user allows a job to read its secrets.
// The alert's own text stays short, so the window fits the screen and its
// buttons stay in view; everything the approval covers goes in a scrolling
// field below it.

import Foundation

public struct SecretApproval: Equatable, Sendable {
    public var job: Job

    public init(job: Job) {
        self.job = job
    }

    public var title: String { "Allow \(job.id) to read its secrets?" }

    /// Secrets and folder; no prompt or command.
    public var summary: String {
        """
        Secrets: \(secrets)
        Folder: \((job.dir as NSString).abbreviatingWithTildeInPath)

        The job can do anything with these values, also send them elsewhere. \
        Allow it only if you wrote it or read it below. A change to what it runs needs a new OK.
        """
    }

    /// What the job runs, in full: what the approval covers.
    public var details: String {
        var parts: [String] = []
        if job.kind == .shell {
            parts.append("Command:\n\(job.command ?? "")")
        } else {
            parts.append("\(job.kind.title) prompt:\n\(job.prompt ?? "")")
        }
        if let model = job.model { parts.append("Model: \(model)") }
        if let mode = job.permissionMode { parts.append("Permission mode: \(mode)") }
        if !job.args.isEmpty { parts.append("Arguments: \(Formatting.joinArgs(job.args))") }
        if !job.env.isEmpty {
            parts.append("Environment:\n" + job.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        }
        parts.append("Secrets: \(secrets)")
        parts.append("Folder: \(job.dir)")
        return parts.joined(separator: "\n\n")
    }

    private var secrets: String {
        job.secretEnv.sorted { $0.key < $1.key }.map { "\($0.key) from \($0.value)" }.joined(separator: ", ")
    }
}
