import AppKit
import LocalCronKit
import SwiftUI
import UniformTypeIdentifiers

/// New job and edit job. The schedule shows what the daemon reads from it
/// as you type.
struct JobEditorView: View {
    @Environment(AppModel.self) private var model
    @State var draft: JobDraft
    @State private var preview: Result<PreviewScheduleResult, Error>?
    @State private var error: String?
    @State private var saving = false
    /// The name of the SVG file chosen in this editor.
    @State private var iconFile: String?
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { model.page = .tabs }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(draft.isNew ? "New Job" : "Edit \(draft.id)").font(.system(size: 13, weight: .semibold))
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
                    whatRuns
                    when
                    if draft.kind != .shell { agent }
                    secrets
                    limits
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .task(id: draft.schedule) { await loadPreview() }
    }

    // MARK: What runs

    private var whatRuns: some View {
        VStack(spacing: 6) {
            SectionLabel("What runs")
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    iconRow
                    RowDivider()
                    Segments(items: JobKind.editorOrder, selection: $draft.kind) { kind, _ in Text(kind.editorTitle) }
                    if draft.kind == .shell {
                        field("Command") {
                            TextField("", text: $draft.command, prompt: Text("make test"), axis: .vertical)
                                .lineLimit(2...6).font(.system(size: 12, design: .monospaced))
                        }
                    } else {
                        field("Prompt") {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("", text: $draft.prompt,
                                          prompt: Text("Review the open pull requests and write a short summary to notes/review.md"),
                                          axis: .vertical)
                                    .lineLimit(3...8)
                                hint("The agent starts with no memory of this chat. Say what to do, where, and where to write the result.")
                            }
                        }
                    }
                    field("Id") {
                        TextField("", text: $draft.id, prompt: Text("weekly-review"))
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(!draft.isNew)
                    }
                    field("Folder") {
                        HStack {
                            TextField("", text: $draft.dir).font(.system(size: 12))
                            SmallButton("Choose…") { chooseFolder() }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var iconRow: some View {
        HStack(alignment: .top, spacing: 12) {
            JobGlyph(job: previewJob, size: 22)
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(dropTarget ? Theme.accentSoft : Theme.neutralSoft, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(dropTarget ? Theme.accentFill : .clear, lineWidth: 1.5))
                .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in drop(providers) }
                .help("Drop an SVG file here")
            VStack(alignment: .leading, spacing: 5) {
                Text("Icon").font(.system(size: 12, weight: .medium))
                Text(iconText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    SmallButton("Choose SVG…") { chooseIcon() }
                    if !draft.icon.isEmpty {
                        SmallButton("Use Default") {
                            draft.icon = ""
                            draft.iconColors = false
                            iconFile = nil
                        }
                    }
                }
                if !draft.icon.isEmpty {
                    Toggle("Keep the SVG's own colors", isOn: $draft.iconColors).toggleStyle(.checkbox).font(.system(size: 12))
                }
                hint("An SVG file up to 64 KB, or drop one on the icon. \(Instance.current.appName) keeps a copy, so you can move or delete the file. Scripts and links in it are removed.")
            }
        }
    }

    private var previewJob: Job {
        Job(id: "preview", schedule: "@daily", kind: draft.kind, dir: "/", icon: draft.icon.isEmpty ? nil : draft.icon,
            iconColors: draft.iconColors)
    }

    private var iconText: String {
        if draft.icon.isEmpty { return "The default icon of \(draft.kind.editorTitle)" }
        let name = iconFile ?? "Your SVG"
        return "\(name), " + (draft.iconColors ? "in its own colors" : "drawn in the text color")
    }

    // MARK: When

    private var when: some View {
        VStack(spacing: 6) {
            SectionLabel("When")
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    let current = SchedulePreset.matching(draft.schedule)
                    HStack(spacing: 6) {
                        ForEach(SchedulePreset.allCases) { preset in
                            Button {
                                draft.schedule = preset.schedule(from: draft.schedule)
                            } label: {
                                Text(preset.title)
                                    .font(.system(size: 11, weight: current == preset ? .semibold : .medium))
                                    .foregroundStyle(current == preset ? Theme.accentSoftText : .primary)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(current == preset ? Theme.accentSoft : Theme.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(current == preset ? Theme.accentFill : Theme.neutralLine, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    field("Schedule") {
                        TextField("", text: $draft.schedule, prompt: Text("0 9 * * wed"))
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    schedulePreview.padding(.leading, 104)
                    RowDivider()
                    Toggle(isOn: $draft.catchUp) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Catch up a missed run").font(.system(size: 12))
                            hint("When the Mac slept or was off at the time, run once when it wakes.")
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var schedulePreview: some View {
        switch preview {
        case let .success(p):
            let times = p.next.compactMap(ApiDate.parse)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.description).font(.system(size: 12, weight: .medium))
                if times.isEmpty {
                    Text("This schedule never runs again.").font(.system(size: 11)).foregroundStyle(Theme.warningText)
                } else {
                    NextTimesStrip(times: times)
                    Text(nextText(times)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        case let .failure(e):
            Text(e.localizedDescription).font(.system(size: 11)).foregroundStyle(Theme.dangerText)
        case nil:
            hint("Cron: minute hour day-of-month month day-of-week, in local time. Once: @at 2026-11-05 09:00, or @in 20m from now.")
        }
    }

    /// "Next: today 12:00, 14:00 and 16:00" or "Next: Monday 09:00,
    /// Tuesday 09:00 and Wednesday 09:00".
    private func nextText(_ times: [Date]) -> String {
        let shown = Array(times.prefix(3))
        let cal = Calendar.current
        let parts = shown.enumerated().map { i, d in
            i > 0 && cal.isDate(d, inSameDayAs: shown[i - 1]) ? Formatting.clock(d) : "\(dayWord(d)) \(Formatting.clock(d))"
        }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "Next: \(list)"
    }

    /// "today", "tomorrow", "Monday", "12 Nov".
    private func dayWord(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: model.now), to: cal.startOfDay(for: date)).day ?? 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        switch days {
        case ...0: return "today"
        case 1: return "tomorrow"
        case 2..<7: f.dateFormat = "EEEE"
        default: f.dateFormat = "d MMM"
        }
        return f.string(from: date)
    }

    // MARK: Agent

    private var agent: some View {
        VStack(spacing: 6) {
            SectionLabel(draft.kind.editorTitle)
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    field("Model") {
                        TextField("", text: $draft.model, prompt: Text("Default")).textFieldStyle(.roundedBorder)
                    }
                    if draft.kind == .claude {
                        field("Permission mode") {
                            Picker("", selection: $draft.permissionMode) {
                                ForEach(JobDraft.permissionModes, id: \.self) { mode in
                                    Text(mode.isEmpty ? "From Claude Code settings" : mode).tag(mode)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    field("More arguments") {
                        TextField("", text: $draft.argsText, prompt: Text(draft.kind == .claude ? "--max-turns 30" : "--full-auto"),
                                  axis: .vertical)
                            .lineLimit(1...4).font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
                    }
                    hint("Nobody is there to approve a tool. A tool that needs approval is refused, unless the permission mode or the arguments allow it.")
                        .padding(.leading, 104)
                }
            }
        }
    }

    // MARK: Secrets

    private var secrets: some View {
        VStack(spacing: 6) {
            SectionLabel(text: "Secrets") {
                Button {
                    draft.secretRows.append(SecretEnvRow())
                } label: {
                    Label("Add variable", systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .disabled(model.secrets.isEmpty)
            }
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($draft.secretRows) { $row in
                        HStack(spacing: 6) {
                            TextField("Variable", text: $row.variable, prompt: Text("GH_TOKEN"))
                                .labelsHidden().font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
                            Text("from").font(.system(size: 11)).foregroundStyle(.secondary)
                            Picker("Secret", selection: $row.secret) {
                                Text("Choose…").tag("")
                                ForEach(secretNames(keeping: row.secret), id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            IconButton(symbol: "minus.circle", help: "Remove", size: 22) {
                                draft.secretRows.removeAll { $0.id == row.id }
                            }
                        }
                    }
                    hint(model.secrets.isEmpty
                         ? "Make a secret in the Secrets tab first."
                         : "After you save, you allow this job to read its secrets, with Touch ID. A change to the prompt, folder or arguments asks again.")
                }
            }
        }
    }

    // MARK: Limits

    private var limits: some View {
        VStack(spacing: 6) {
            SectionLabel("Limits")
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    field("Stop a run after") {
                        HStack(spacing: 6) {
                            Stepper("\(draft.timeoutMinutes) min", value: $draft.timeoutMinutes, in: 1...10080)
                                .font(.system(size: 12).monospacedDigit())
                            Spacer()
                        }
                    }
                    field("On") {
                        HStack {
                            Toggle("", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Spacer()
                        }
                    }
                    field("Note") {
                        TextField("", text: $draft.note, prompt: Text("Why this job exists")).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    // MARK: Parts

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Icon"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { useIcon(url) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in useIcon(url) }
        }
        return true
    }

    /// Reads the SVG; the daemon removes scripts and links when it saves.
    private func useIcon(_ url: URL) {
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 64 * 1024 else {
                error = "\(url.lastPathComponent) is \(size / 1024) KB; an icon may be at most 64 KB."
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.range(of: "<svg", options: .caseInsensitive) != nil, SVGImage.image(text) != nil else {
                error = "\(url.lastPathComponent) is not an SVG drawing."
                return
            }
            draft.icon = text
            iconFile = url.lastPathComponent
            error = nil
        } catch {
            self.error = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
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

/// The next times of a schedule on a day line, 00:00 to 24:00, for the
/// day of the first time.
struct NextTimesStrip: View {
    let times: [Date]

    var body: some View {
        let cal = Calendar.current
        let day = cal.startOfDay(for: times[0])
        let today = times.filter { cal.isDate($0, inSameDayAs: day) }
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.neutralLine).frame(height: 1).offset(y: 6)
                    ForEach(today, id: \.self) { t in
                        Circle().strokeBorder(Theme.accentFill, lineWidth: 1.5).background(Circle().fill(Theme.card))
                            .frame(width: 8, height: 8)
                            .position(x: CGFloat(t.timeIntervalSince(day) / 86400) * geo.size.width, y: 6.5)
                    }
                }
            }
            .frame(height: 13)
            HStack(spacing: 0) {
                ForEach(["00:00", "06:00", "12:00", "18:00"], id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

extension JobKind {
    /// The order of the editor's segments.
    static let editorOrder: [JobKind] = [.claude, .codex, .shell]

    var editorTitle: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .shell: "Shell command"
        }
    }
}
