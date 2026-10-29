import LocalCronKit
import SwiftUI

/// The secrets jobs can use: names, descriptions and state. Never a value.
struct SecretsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.secrets.isEmpty {
                empty
            } else {
                List(model.secrets) { secret in
                    SecretRow(secret: secret)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button {
                    model.newSecret()
                } label: {
                    Label("New Secret", systemImage: "plus")
                }
                .disabled(!model.running)
                Spacer()
            }
            .padding(8)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "key").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No secrets yet").font(.headline)
            Text("A secret is a value a job gets as an environment variable, such as an API token. It is kept in your login keychain, so runs at night can read it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Add one with New Secret, or in a terminal: \(Instance.current.cli) secret set NAME")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SecretRow: View {
    @Environment(AppModel.self) private var model
    let secret: SecretInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: secret.state.symbol)
                .foregroundStyle(secret.state.color)
                .help(secret.state.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(secret.name).font(.body.weight(.medium))
                if !secret.description.isEmpty {
                    Text(secret.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .textSelection(.enabled)
                }
                if secret.state != .ok {
                    Text("\(secret.state.title): \(secret.message)").font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
                HStack(spacing: 10) {
                    if let set = ApiDate.parse(secret.updatedAt) {
                        Text("Set \(Formatting.past(set))").font(.caption).foregroundStyle(.secondary)
                    }
                    if !secret.usedBy.isEmpty {
                        Text("Used by \(secret.usedBy.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            Button("New Value…") { model.edit(secret) }
                .controlSize(.small)
                .help("Paste a new value; the description stays")
        }
        .padding(.vertical, 4)
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
                Button {
                    model.page = .tabs
                } label: {
                    Label("Secrets", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(draft.isNew ? "New Secret" : draft.name).font(.headline)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("github-token"))
                        .disabled(!draft.isNew)
                    SecureField("Value", text: $draft.value,
                                prompt: Text(draft.isNew ? "Paste the token or key" : "Leave empty to keep the value"))
                    Text("Kept in your login keychain. Only the \(Instance.current.appName) daemon reads it, when a job that you allowed runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("How to make a new one") {
                    TextField("Description", text: $draft.description,
                              prompt: Text("Fine-grained token, repo shop, Contents read/write, github.com/settings/tokens, expires 2027-01-31"),
                              axis: .vertical)
                        .lineLimit(2...6)
                    Text("Where the value comes from, its rights, when it expires: so you can replace it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
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
