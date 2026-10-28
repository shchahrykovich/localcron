import LocalCronKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void
    @State private var openAtLogin = OpenAtLogin().isOn
    @AppStorage("autoUpdate") private var autoUpdate = true

    var body: some View {
        Form {
            Section("Runs") {
                if let config = model.config {
                    Stepper("At most \(config.maxConcurrent) at a time",
                            value: Binding(get: { Int(config.maxConcurrent) },
                                           set: { n in Task { await model.setConfig(maxConcurrent: UInt32(n)) } }),
                            in: 1...16)
                    Stepper("Keep the last \(config.keepRuns) runs of each job",
                            value: Binding(get: { Int(config.keepRuns) },
                                           set: { n in Task { await model.setConfig(keepRuns: UInt32(n)) } }),
                            in: 1...1000, step: 5)
                } else {
                    Text("The daemon is not running.").foregroundStyle(.secondary)
                }
                Button("Show Run Logs Folder") { model.openLogsFolder() }
            }
            Section("Coding agents") {
                agentButton("Add to Claude Code", detail: "Adds the MCP server and a note to ~/.claude/CLAUDE.md.", action: .installClaude)
                agentButton("Add to Codex", detail: "Adds the MCP server to config.toml and a note to AGENTS.md.", action: .installCodex)
                agentButton("Install Command Line Tool", detail: model.cliInstalled ? "Installed in ~/.local/bin." : "Links \(Instance.current.cli) into ~/.local/bin.",
                            action: .installCLI)
                HStack {
                    Text(model.mcpCommand).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { perform(.copyMCPCommand) }.controlSize(.small)
                }
            }
            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        if let problem = OpenAtLogin().choose(on) { model.say(problem, failed: true) }
                        openAtLogin = OpenAtLogin().isOn
                    }
                if let note = OpenAtLogin().note {
                    Button(note) { model.openLoginItems() }.buttonStyle(.link)
                }
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                HStack {
                    Text("Version \(model.version)")
                    Spacer()
                    updateControl
                }
            }
            Section("Daemon") {
                if let status = model.status {
                    LabeledContent("Version", value: "\(status.daemonVersion), pid \(status.pid)")
                    LabeledContent("Jobs", value: "\(status.enabledJobs) on, \(status.jobs) in all")
                    LabeledContent("Data") {
                        Text((status.dataDir as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                    }
                } else {
                    Text(model.daemonProblem ?? "Not running.").foregroundStyle(.orange)
                }
                if let note = model.serviceNote {
                    Text(note).foregroundStyle(.orange)
                }
            }
            Section {
                HStack {
                    Button("Uninstall \(Instance.current.appName)…", role: .destructive) {
                        if confirm("Uninstall \(Instance.current.appName)?",
                                   "This stops the daemon and deletes every job, run and log, the command line tool link, the notes and the Claude Code MCP server.",
                                   button: "Uninstall") {
                            Task { await model.uninstall() }
                        }
                    }
                    Spacer()
                    Button("Quit") { perform(.quit) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy)
    }

    private func agentButton(_ title: String, detail: String, action: AppMenu.Action) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(title.hasPrefix("Install") ? "Install" : "Add") { perform(action) }
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch model.update {
        case .idle, .upToDate, .failed:
            HStack {
                if case .upToDate = model.update { Text("Up to date").font(.caption).foregroundStyle(.secondary) }
                if case let .failed(why) = model.update { Text(why).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Button("Check for Updates") { perform(.checkForUpdates) }
            }
        case .checking:
            ProgressView().controlSize(.small)
        case let .available(release):
            Button("Install \(release.version)") { Task { await model.installUpdate(release) } }
        case let .downloading(release):
            HStack {
                ProgressView().controlSize(.small)
                Text("Installing \(release.version)…").font(.caption)
            }
        }
    }
}
