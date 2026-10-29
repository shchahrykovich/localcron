import AppKit
import LocalCronKit
import SwiftUI

/// New job and edit job. The schedule field shows what the daemon reads from
/// it as you type.
struct JobEditorView: View {
    @Environment(AppModel.self) private var model
    @State var draft: JobDraft
    @State private var preview: Result<PreviewScheduleResult, Error>?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.page = .tabs
                } label: {
                    Label("Jobs", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(draft.isNew ? "New Job" : "Edit \(draft.id)").font(.headline)
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
                    TextField("Id", text: $draft.id, prompt: Text("weekly-review"))
                        .disabled(!draft.isNew)
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(JobKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if draft.kind == .shell {
                        TextField("Command", text: $draft.command, prompt: Text("make test"), axis: .vertical)
                            .lineLimit(2...6)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        TextField("Prompt", text: $draft.prompt,
                                  prompt: Text("Review the open pull requests and write a summary to notes/review.md"),
                                  axis: .vertical)
                            .lineLimit(3...8)
                    }
                    HStack {
                        TextField("Folder", text: $draft.dir)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Section {
                    TextField("Schedule", text: $draft.schedule, prompt: Text("0 9 * * wed"))
                        .font(.system(.body, design: .monospaced))
                    schedulePreview
                }
                if draft.kind != .shell {
                    Section("Agent") {
                        TextField("Model", text: $draft.model, prompt: Text("default"))
                        if draft.kind == .claude {
                            Picker("Permission mode", selection: $draft.permissionMode) {
                                ForEach(JobDraft.permissionModes, id: \.self) { mode in
                                    Text(mode.isEmpty ? "From Claude Code settings" : mode).tag(mode)
                                }
                            }
                        }
                        TextField("More arguments", text: $draft.argsText,
                                  prompt: Text(draft.kind == .claude ? "--max-turns 30" : "--full-auto"), axis: .vertical)
                            .lineLimit(1...4)
                            .font(.system(.body, design: .monospaced))
                        Text("The run has no person to approve tools. A tool that needs approval is refused, unless the permission mode or the arguments allow it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Secrets") {
                    ForEach($draft.secretRows) { $row in
                        HStack {
                            TextField("Variable", text: $row.variable, prompt: Text("GH_TOKEN"))
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                            Image(systemName: "arrow.left").foregroundStyle(.secondary)
                            Picker("Secret", selection: $row.secret) {
                                Text("Choose…").tag("")
                                ForEach(secretNames(keeping: row.secret), id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            Button {
                                draft.secretRows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        draft.secretRows.append(SecretEnvRow())
                    } label: {
                        Label("Add Secret Variable", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.secrets.isEmpty)
                    Text(model.secrets.isEmpty
                         ? "Make a secret in the Secrets tab first."
                         : "The run gets each secret as its variable. After you save, you allow the job to read them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Stepper("Stop after \(draft.timeoutMinutes) min", value: $draft.timeoutMinutes, in: 1...10080)
                    Toggle("Catch up a run missed while the Mac slept or was off", isOn: $draft.catchUp)
                    Toggle("On", isOn: $draft.enabled)
                    TextField("Note", text: $draft.note, prompt: Text("Why this job exists"))
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        }
        .task(id: draft.schedule) { await loadPreview() }
    }

    @ViewBuilder
    private var schedulePreview: some View {
        switch preview {
        case let .success(p):
            VStack(alignment: .leading, spacing: 2) {
                Text(p.description).font(.callout)
                ForEach(p.next, id: \.self) { at in
                    if let date = ApiDate.parse(at) {
                        Text(Formatting.next(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if p.next.isEmpty {
                    Text("This schedule never runs again.").font(.caption).foregroundStyle(.orange)
                }
            }
        case let .failure(e):
            Text(e.localizedDescription).font(.caption).foregroundStyle(.red)
        case nil:
            Text("Cron: minute hour day-of-month month day-of-week, in local time. Once: @at 2026-11-05 09:00, or @in 20m from now.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadPreview() async {
        let text = draft.schedule.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            preview = nil
            return
        }
        // Wait for the typing to stop.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        preview = await model.preview(text)
    }

    /// The secrets that exist, and the row's own when it is gone, so the
    /// picker can show it.
    private func secretNames(keeping current: String) -> [String] {
        var names = model.secrets.map(\.name)
        if !current.isEmpty && !names.contains(current) { names.append(current) }
        return names
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.dir)
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            draft.dir = url.path
        }
    }

    private func save() {
        saving = true
        Task {
            error = await model.save(draft)
            saving = false
        }
    }
}
