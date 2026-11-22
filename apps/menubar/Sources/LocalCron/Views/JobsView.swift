import LocalCronKit
import SwiftUI

/// The Jobs page: a filter by job id, jobs that wait for the user's OK,
/// then all jobs in one card, the next to run first.
struct JobsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.jobs.isEmpty {
            EmptyJobsView()
        } else {
            let jobs = JobGroups.ordered(JobGroups.filter(model.jobs, query: model.jobFilter))
            VStack(spacing: 0) {
                FilterField(prompt: "Filter by job", text: $model.jobFilter)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.jobs.filter { $0.secretsAllowed == false }) { WaitingBanner(job: $0) }
                        if !model.failedJobs.isEmpty { FailedBanner(jobs: model.failedJobs) }
                        if jobs.isEmpty {
                            VStack(spacing: 6) {
                                Text("No job matches").font(.system(size: 13, weight: .medium))
                                Text("Clear the job filter.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.top, 40)
                        } else {
                            Card {
                                ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                                    if i > 0 { RowDivider() }
                                    JobRow(job: job)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

/// "issue-digest waits for your OK to read github-token." and Allow….
struct WaitingBanner: View {
    @Environment(AppModel.self) private var model
    let job: JobView

    var body: some View {
        let names = Array(Set(job.job.secretEnv.values)).sorted()
        HStack(spacing: 10) {
            Image(systemName: "key").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.warningText)
            (Text(job.id).fontWeight(.semibold) + Text(" waits for your OK to read ")
                + Text(names.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)) + Text("."))
                .font(.system(size: 12)).foregroundStyle(Theme.warningText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await model.allowSecrets(job) }
            } label: {
                Text("Allow…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.warningText, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Read what the job runs, then allow it with Touch ID or your password")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warningLine, lineWidth: 1))
    }
}

/// Jobs whose last run failed: the reason for the red mark on the icon.
/// Dismiss hides the mark until a job fails again.
struct FailedBanner: View {
    @Environment(AppModel.self) private var model
    let jobs: [JobView]

    /// The job's own note when it reported the error, else how it ended.
    static func why(_ run: Run) -> String {
        if let note = run.reported?.note, !note.isEmpty { return note }
        return run.exitCode.map { "exit \($0)" } ?? run.status.title.lowercased()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dangerText)
            VStack(alignment: .leading, spacing: 3) {
                Text(jobs.count == 1 ? "The last run of 1 job failed." : "The last run of \(jobs.count) jobs failed.")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(jobs) { job in
                    if let last = job.lastRun {
                        Button {
                            model.showLog(last)
                        } label: {
                            (Text(job.id).fontWeight(.medium) + Text(": " + Self.why(last)))
                                .font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Open the log of this run")
                    }
                }
            }
            .foregroundStyle(Theme.dangerText)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.dismissFailures()
            } label: {
                Text("Dismiss").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dangerText)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.dangerLine, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Hide the red mark until a job fails again. The runs stay in Runs.")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.dangerLine, lineWidth: 1))
    }
}

struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: JobView
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            JobTile(job: job, ground: hovering ? Theme.rowHover : Theme.card)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(job.id).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Chip(text: job.job.kind.title)
                    if job.job.schedule.hasPrefix("@at ") { Chip(text: "Once", kind: .accent) }
                    if job.secretsAllowed == false { Chip(text: "Secrets not allowed", kind: .warning) }
                }
                detail
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.edit(job) }
        .help(JobGroups.tilde(job.job.dir))
        .contextMenu { JobMenu(job: job) }
    }

    @ViewBuilder private var detail: some View {
        if let active = job.activeRun {
            let line = active.status == .queued
                ? "Waits for a free slot"
                : "Running for \(active.seconds(now: model.now).map { Formatting.duration($0) } ?? "a moment")"
                    + (active.trigger == .manual ? ", you started it" : "")
            Text(line).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent).lineLimit(1)
        } else if let last = job.lastRun, last.failed, job.secretsAllowed != false {
            Button {
                model.showLog(last)
            } label: {
                Text(failedText(last)).font(.system(size: 11))
                    .foregroundStyle(model.dismissedRuns.contains(last.id) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.dangerText))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        } else {
            Text(job.scheduleText + (job.job.schedule.hasPrefix("@at ") ? ", then removed" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .help(job.job.schedule)
        }
    }

    private func failedText(_ run: Run) -> String {
        let at = run.shownAt.map { " at \(Formatting.when($0, now: model.now))" } ?? ""
        let why = run.status == .timedOut ? "Stopped\(at), its time limit" :
            !run.status.isFailure ? "Reported an error\(at)" :
            run.exitCode.map { "Failed\(at) with exit code \($0)" } ?? "Failed\(at)"
        return why + ". Show log"
    }

    @ViewBuilder private var trailing: some View {
        if let active = job.activeRun {
            HStack(spacing: 6) {
                if active.console != nil {
                    SmallButton("Terminal") { model.openTerminal(active) }
                        .help("Its Claude Code console: watch it and type into it")
                }
                SmallButton("Stop") { Task { await model.cancel(active) } }
            }
        } else if hovering {
            HStack(spacing: 2) {
                IconButton(symbol: "play.fill", help: "Run now, as an extra run") { Task { await model.runNow(job) } }
                IconButton(symbol: "pencil", help: "Edit") { model.edit(job) }
                Menu { JobMenu(job: job) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 26)
                    .help("More for \(job.id)")
            }
        } else if !job.job.enabled {
            Text("Off").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if model.paused {
            Text("Paused").font(.system(size: 11)).foregroundStyle(Theme.warningText)
        } else if let next = ApiDate.parse(job.nextRun) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatting.clock(next)).font(.system(size: 11, weight: .medium).monospacedDigit())
                Text(dayWord(next)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .help("Next run \(Formatting.next(next, now: model.now))")
        }
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
}

/// The commands of a job: its "…" button and its right-click menu.
struct JobMenu: View {
    @Environment(AppModel.self) private var model
    let job: JobView

    var body: some View {
        Button("Run Now") { Task { await model.runNow(job) } }
        if let next = ApiDate.parse(job.nextRun) {
            Button("Run Now, Instead of \(Formatting.next(next))") { Task { await model.runNow(job, early: true) } }
        }
        Button("Edit…") { model.edit(job) }
        Button(job.job.enabled ? "Turn Off" : "Turn On") { Task { await model.setEnabled(job, !job.job.enabled) } }
        if job.secretsAllowed == false {
            Button("Allow Secrets…") { Task { await model.allowSecrets(job) } }
        }
        if let active = job.activeRun {
            Divider()
            if let console = active.console {
                Button("Open Terminal") { model.openTerminal(active) }
                Button("Copy Terminal Command") { model.copy(console) }
            }
            Button("Stop \(active.id)") { Task { await model.cancel(active) } }
            Button("Kill \(active.id) Now") { Task { await model.cancel(active, kill: true) } }
        }
        Button("Copy Prompt for Another Mac") { model.copySharePrompt([job]) }
            .help("A prompt for Claude Code or Codex on another Mac that makes this job there")
        Divider()
        Button("Show Runs") { model.showRuns(jobID: job.id) }
        if job.job.kind != .shell {
            Button("Show Token Usage") { model.showUsage(jobID: job.id) }
        }
        if let run = job.activeRun ?? job.lastRun {
            Button("Show Log") { model.showLog(run) }
            Button("Reveal Log in Finder") { model.revealLog(run) }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            if confirm("Delete \(job.id)?", "The job, its runs and their logs are deleted. A running run is stopped.", button: "Delete") {
                Task { await model.delete(job) }
            }
        }
    }
}

/// No jobs yet: how to make the first one, here or with an agent.
struct EmptyJobsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No jobs yet").font(.system(size: 15, weight: .semibold))
                    Text("Run a command or a coding agent on a timer, with no terminal open. For example: every Wednesday at 09:00, review the open pull requests.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Here, with a form").font(.system(size: 12, weight: .semibold))
                        Text("Choose what runs, the folder and the time. The schedule shows its next runs as you type.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        SmallButton("+ New Job", prominent: true) { model.newJob() }.disabled(!model.running)
                    }
                }
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or ask Claude Code or Codex").font(.system(size: 12, weight: .semibold))
                        step(1, "Add the MCP server. Settings does it for you, or run:")
                        CopyLine(text: model.mcpCommand)
                        step(2, "In a project folder, ask the agent in your own words:")
                        Text("“Every weekday at 08:30, sum up the new GitHub issues in notes/issues.md.”")
                            .font(.system(size: 12)).italic().padding(.leading, 24).fixedSize(horizontal: false, vertical: true)
                        LinkButton("Add to Claude Code or Codex in Settings") { model.openSettings(.agents) }.padding(.leading, 24)
                    }
                }
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or from a terminal").font(.system(size: 12, weight: .semibold))
                        CopyLine(text: "\(Instance.current.cli) add nightly-tests --schedule \"0 2 * * *\" --command \"make test\"", prompt: "$")
                    }
                }
                LinkButton("Open the help page") { model.openHelp() }.padding(.horizontal, 4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accentSoftText)
                .frame(width: 16, height: 16).background(Theme.accentSoft, in: Circle())
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
