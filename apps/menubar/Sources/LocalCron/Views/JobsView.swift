import LocalCronKit
import SwiftUI

struct JobsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.jobs.isEmpty {
                empty
            } else {
                List(model.jobs) { job in
                    JobRow(job: job)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button {
                    model.newJob()
                } label: {
                    Label("New Job", systemImage: "plus")
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
            Image(systemName: "clock.badge.questionmark").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No jobs yet").font(.headline)
            Text("Add a job with New Job, or ask Claude Code or Codex in any project:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("“Every Wednesday at 9, run a Claude agent that reviews the open pull requests.”")
                .italic()
                .multilineTextAlignment(.center)
            Text("For that, choose Add to Claude Code or Add to Codex in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: JobView

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { job.job.enabled },
                                     set: { on in Task { await model.setEnabled(job, on) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(job.job.enabled ? "Turn off" : "Turn on")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.id).font(.body.weight(.medium))
                    KindBadge(kind: job.job.kind)
                }
                Text(job.scheduleText).font(.caption).foregroundStyle(.secondary)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    if model.paused && job.job.enabled {
                        Text("Paused").font(.caption).foregroundStyle(.orange)
                    } else if let next = job.nextRun.flatMap(ApiDate.parse) {
                        Text("Next \(Formatting.next(next))").font(.caption)
                    } else if !job.job.enabled {
                        Text("Off").font(.caption).foregroundStyle(.secondary)
                    }
                    if let last = job.lastRun {
                        HStack(spacing: 3) {
                            Image(systemName: last.status.symbol).foregroundStyle(last.status.color)
                            Text("\(last.status.title) \(last.started.map { Formatting.past($0) } ?? "")")
                        }
                        .font(.caption)
                        .help(last.message)
                    }
                }
            }
            Spacer(minLength: 4)
            if let active = job.activeRun {
                VStack(alignment: .trailing, spacing: 4) {
                    StatusLabel(status: active.status).font(.caption)
                    Button("Stop") { Task { await model.cancel(active) } }
                        .controlSize(.small)
                }
            } else {
                Button {
                    Task { await model.runNow(job) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .controlSize(.small)
                .help("Run now")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.edit(job) }
        .contextMenu {
            Button("Edit…") { model.edit(job) }
            Button("Run Now") { Task { await model.runNow(job) } }
            if let active = job.activeRun {
                Button("Stop \(active.id)") { Task { await model.cancel(active) } }
                Button("Kill \(active.id) Now") { Task { await model.cancel(active, kill: true) } }
            }
            Divider()
            if let run = job.activeRun ?? job.lastRun {
                Button("Show Log") { model.showLog(run) }
                Button("Reveal Log in Finder") { model.revealLog(run) }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                if confirm("Delete \(job.id)?", "The job, its runs and their logs are deleted. A running run is stopped.",
                           button: "Delete") {
                    Task { await model.delete(job) }
                }
            }
        }
    }

    /// The prompt or the command, on one line.
    private var summary: String {
        let text = job.job.kind == .shell ? job.job.command ?? "" : job.job.prompt ?? ""
        let folder = (job.job.dir as NSString).abbreviatingWithTildeInPath
        return "\(folder): \(text.replacingOccurrences(of: "\n", with: " "))"
    }
}
