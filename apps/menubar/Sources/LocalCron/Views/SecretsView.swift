import LocalCronKit
import SwiftUI

/// The secrets jobs can use: names, descriptions and state. Never a value.
struct SecretsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.jobs.filter { $0.secretsAllowed == false }
        ScrollView {
            VStack(spacing: 12) {
                if !waiting.isEmpty {
                    VStack(spacing: 6) {
                        SectionLabel("Waiting for your OK")
                        Card {
                            ForEach(Array(waiting.enumerated()), id: \.element.id) { i, job in
                                if i > 0 { RowDivider() }
                                WaitingRow(job: job)
                            }
                        }
                    }
                }
                if model.secrets.isEmpty {
                    empty
                } else {
                    VStack(spacing: 6) {
                        SectionLabel(text: "In your login keychain") {
                            Text(model.secrets.count == 1 ? "1 secret" : "\(model.secrets.count) secrets")
                        }
                        Card {
                            ForEach(Array(model.secrets.enumerated()), id: \.element.id) { i, secret in
                                if i > 0 { RowDivider() }
                                SecretRow(secret: secret)
                            }
                        }
                    }
                    Text("The app never shows a value. Only the \(Instance.current.appName) daemon reads it, for a job you allowed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var empty: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No secrets yet").font(.system(size: 13, weight: .semibold))
                Text("A secret is a value a job gets as an environment variable, such as an API token. It is kept in your login keychain, so runs at night can read it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Add one with New Secret, or in a terminal:").font(.system(size: 12)).foregroundStyle(.secondary)
                CopyLine(text: "\(Instance.current.cli) secret set NAME", prompt: "$")
            }
        }
    }
}

/// A job that may not read its secrets yet.
struct WaitingRow: View {
    @Environment(AppModel.self) private var model
    let job: JobView

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            JobTile(job: job)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.id).font(.system(size: 13, weight: .medium))
                ForEach(job.job.secretEnv.sorted { $0.key < $1.key }, id: \.key) { variable, secret in
                    (Text("Wants ") + Text(variable).font(Theme.mono) + Text(" from ") + Text(secret).font(Theme.mono))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if job.job.kind != .shell {
                    Text("\(job.job.kind.title) can send what it reads to its model.")
                        .font(.system(size: 11)).foregroundStyle(Theme.warningText)
                }
            }
            Spacer(minLength: 4)
            SmallButton("Allow…", prominent: true) { Task { await model.allowSecrets(job) } }
                .help("Read what the job runs, then allow it with Touch ID or your password")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct SecretRow: View {
    @Environment(AppModel.self) private var model
    let secret: SecretInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: secret.state == .ok ? "key.fill" : "exclamationmark.lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(secret.state == .ok ? Color.secondary : Theme.warningText)
                .frame(width: 24, height: 24)
                .background(secret.state == .ok ? Theme.neutralSoft : Theme.warningSoft, in: RoundedRectangle(cornerRadius: 6))
                .help(secret.state.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(secret.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                if !secret.description.isEmpty {
                    Text(secret.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if secret.state != .ok {
                    Text(secret.message.isEmpty ? secret.state.title : secret.message)
                        .font(.system(size: 11)).foregroundStyle(Theme.warningText).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(usage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            SmallButton(secret.state == .ok ? "New Value…" : "Set Again…") { model.edit(secret) }
                .help("Paste a new value; the description stays")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.edit(secret) }
        .contextMenu {
            Button("New Value or Description…") { model.edit(secret) }
            Button("Copy Terminal Command") { model.copy(secret.setCommand) }
            Divider()
            Button("Delete…", role: .destructive) {
                let used = secret.usedBy.isEmpty ? "" : " Runs of \(secret.usedBy.joined(separator: ", ")) fail until it is set again."
                if confirm("Delete \(secret.name)?", "The value is removed from the Keychain.\(used)", button: "Delete") {
                    Task { await model.delete(secret) }
                }
            }
        }
    }

    /// "Used by pr-review and issue-digest. Set 12 days ago."
    private var usage: String {
        let used: String
        switch secret.usedBy.count {
        case 0: used = "No job uses it."
        case 1: used = "Used by \(secret.usedBy[0])."
        default: used = "Used by \(secret.usedBy.dropLast().joined(separator: ", ")) and \(secret.usedBy.last!)."
        }
        guard let set = ApiDate.parse(secret.updatedAt) else { return used }
        return "\(used) Set \(Formatting.past(set, now: model.now))."
    }
}

/// New secret, or a new value or description for one. The value field never
/// shows the stored value: the app does not have it.
struct SecretEditorView: View {
    @Environment(AppModel.self) private var model
    @State var draft: SecretDraft
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { model.page = .tabs }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(draft.isNew ? "New Secret" : draft.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                SmallButton(saving ? "Saving…" : "Save", prominent: true) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ScrollView {
                VStack(spacing: 12) {
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.dangerText).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            row("Name") {
                                TextField("", text: $draft.name, prompt: Text("github-token"))
                                    .font(.system(size: 12, design: .monospaced))
                                    .disabled(!draft.isNew)
                            }
                            row("Value") {
                                SecureField("", text: $draft.value,
                                            prompt: Text(draft.isNew ? "Paste the token or key" : "Leave empty to keep the value"))
                            }
                            Text("Kept in your login keychain. Only the \(Instance.current.appName) daemon reads it, when a job that you allowed runs.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    VStack(spacing: 6) {
                        SectionLabel("How to make a new one")
                        Card(padding: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("", text: $draft.description,
                                          prompt: Text("Fine-grained token, repo shop, Contents read/write, github.com/settings/tokens, expires 2027-01-31"),
                                          axis: .vertical)
                                    .lineLimit(2...6)
                                    .textFieldStyle(.roundedBorder)
                                Text("Where the value comes from, its rights, when it expires: so you can replace it.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            content()
        }
    }

    private func save() {
        saving = true
        Task {
            error = await model.save(draft)
            // Do not keep the value in memory longer than needed.
            if error == nil { draft.value = "" }
            saving = false
        }
    }
}
