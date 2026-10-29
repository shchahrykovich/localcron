import LocalCronKit
import SwiftUI

/// The newest runs of every job. A click opens the run's log.
struct RunsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.runs.isEmpty {
            VStack {
                Spacer()
                Text("No runs yet").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(model.runs) { run in
                Button {
                    model.showLog(run)
                } label: {
                    RunRow(run: run)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Show Log") { model.showLog(run) }
                    Button("Reveal Log in Finder") { model.revealLog(run) }
                    if !run.status.isFinished {
                        Button("Stop") { Task { await model.cancel(run) } }
                        Button("Kill Now") { Task { await model.cancel(run, kill: true) } }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct RunRow: View {
    let run: Run

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: run.status.symbol).foregroundStyle(run.status.color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.jobId).font(.body.weight(.medium))
                    Text(run.trigger.title).font(.caption).foregroundStyle(.secondary)
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(run.started.map { Formatting.past($0) } ?? "").font(.caption)
                if let seconds = run.seconds {
                    Text(Formatting.duration(seconds)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var details: String {
        var parts = [run.status.title]
        if let code = run.exitCode { parts.append("exit \(code)") }
        if !run.message.isEmpty { parts.append(run.message) }
        return parts.joined(separator: " · ")
    }
}

/// The output of one run. Refreshes itself while the run is not finished.
struct RunLogView: View {
    @Environment(AppModel.self) private var model
    let runID: String
    @State private var log: GetRunLogResult?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.page = .tabs
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(runID).font(.headline)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let log {
                HStack {
                    StatusLabel(status: log.run.status).font(.caption)
                    if let code = log.run.exitCode { Text("exit \(code)").font(.caption) }
                    if let seconds = log.run.seconds { Text(Formatting.duration(seconds)).font(.caption) }
                    Spacer()
                    Button("Reveal in Finder") { model.revealLog(log.run) }.controlSize(.small)
                    if log.run.console != nil {
                        Button("Open Terminal") { model.openTerminal(log.run) }.controlSize(.small)
                            .help("The run's Claude Code console: watch it and type into it")
                    }
                    Button("Open in Console.app") { model.openLogInConsole(log.run) }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if !log.run.message.isEmpty {
                    Text(log.run.message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text((log.truncated ? "… (only the end of \(log.size) bytes)\n" : "") + log.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .defaultScrollAnchor(.bottom)
                .background(Color(nsColor: .textBackgroundColor))
            } else if let error {
                Text(error).foregroundStyle(.red).padding()
                Spacer()
            } else {
                ProgressView().padding()
                Spacer()
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                if log?.run.status.isFinished == true { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func load() async {
        switch await model.log(runID) {
        case let .success(l):
            log = l
            error = nil
        case let .failure(e):
            error = e.localizedDescription
        }
    }
}
