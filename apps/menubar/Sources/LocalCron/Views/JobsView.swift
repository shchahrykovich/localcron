import LocalCronKit
import SwiftUI

/// The Jobs tab: today's runs on a strip, jobs that wait for the user's
/// OK, then the jobs grouped by folder.
struct JobsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.jobs.isEmpty {
            EmptyJobsView()
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    TodayCard()
                    ForEach(model.jobs.filter { $0.secretsAllowed == false }) { WaitingBanner(job: $0) }
                    ForEach(JobGroups.byFolder(model.jobs)) { FolderSection(folder: $0) }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }
}

/// Twelve hours of today: what ran, what works now, what comes.
struct TodayCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let strip = DayStrip(now: model.now)
        let marks = strip.marks(model.timeMarks(from: model.runs))
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Today").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    nextText.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { geo in
                    stripView(strip, marks: marks, width: geo.size.width)
                }
                .frame(height: 22)
                GeometryReader { geo in
                    labels(strip, width: geo.size.width)
                }
                .frame(height: 13)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 8)
        }
    }

    private var nextText: Text {
        if model.paused { return Text("Paused: scheduled runs do not start") }
        guard let next = model.status?.next, let at = ApiDate.parse(next.at) else { return Text("No run is planned") }
        let soon = Formatting.soon(at, now: model.now)
        let when = soon.contains(", in") ? "at \(soon)" : soon
        return Text("Next: ") + Text(next.jobId).foregroundColor(.primary).fontWeight(.medium) + Text(" \(when)")
    }

    private func stripView(_ strip: DayStrip, marks: [TimeMark], width: CGFloat) -> some View {
        let x = { (d: Date) in CGFloat(strip.fraction(d)) * width }
        let nowX = x(model.now)
        return ZStack(alignment: .topLeading) {
            // The past part of the strip.
            RoundedRectangle(cornerRadius: 4).fill(Theme.ground).frame(width: max(0, nowX), height: 22)
            Rectangle().fill(Theme.neutralLine).frame(height: 1).offset(y: 11)
            ForEach(strip.labels, id: \.self) { label in
                Rectangle().fill(Theme.neutralLine).frame(width: 1, height: 7).offset(x: min(x(label), width - 1), y: 8)
            }
            ForEach(marks) { mark in
                dot(mark).position(x: x(mark.start), y: 11)
                    .help("\(mark.jobID) \(mark.mark == .planned ? "at" : mark.mark.title.lowercased() + " at") \(Formatting.clock(mark.start))")
            }
            RoundedRectangle(cornerRadius: 1).fill(Theme.accentFill).frame(width: 2, height: 22).offset(x: nowX - 1)
        }
        .frame(width: width, height: 22, alignment: .topLeading)
    }

    @ViewBuilder private func dot(_ mark: TimeMark) -> some View {
        switch mark.mark {
        case .planned:
            Circle().strokeBorder(Theme.accentFill, lineWidth: 1.5).background(Circle().fill(Theme.card)).frame(width: 8, height: 8)
        case .working:
            Circle().fill(Theme.accentFill).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Theme.accentRing, lineWidth: 3).padding(-3))
        default:
            Circle().fill(mark.mark.solid).frame(width: 8, height: 8)
        }
    }

    private func labels(_ strip: DayStrip, width: CGFloat) -> some View {
        let nowX = CGFloat(strip.fraction(model.now)) * width
        return ZStack(alignment: .topLeading) {
            ForEach(Array(strip.labels.enumerated()), id: \.offset) { i, label in
                let lx = CGFloat(strip.fraction(label)) * width
                // A label under the "now" label is left out.
                if abs(lx - nowX) > 34 {
                    Text(Formatting.clock(label))
                        .frame(width: 40, alignment: i == 0 ? .leading : i == strip.labels.count - 1 ? .trailing : .center)
                        .offset(x: i == 0 ? 0 : i == strip.labels.count - 1 ? width - 40 : lx - 20)
                }
            }
            Text(Formatting.clock(model.now)).foregroundStyle(Theme.accent).fontWeight(.semibold)
                .frame(width: 40).offset(x: min(max(0, nowX - 20), width - 40))
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: width, alignment: .topLeading)
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

/// The jobs of one folder: a header that folds them, and a card.
struct FolderSection: View {
    @Environment(AppModel.self) private var model
    let folder: JobFolder

    var body: some View {
        let open = !model.closedFolders.contains(folder.dir)
        VStack(spacing: 6) {
            Button {
                if open { model.closedFolders.insert(folder.dir) } else { model.closedFolders.remove(folder.dir) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 10)
                    Text(folder.title).fontWeight(.semibold).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(folder.summary).fontWeight(.medium)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folder.dir)
            if open {
                Card {
                    ForEach(Array(folder.jobs.enumerated()), id: \.element.id) { i, job in
                        if i > 0 { RowDivider() }
                        JobRow(job: job)
                    }
                }
            }
        }
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
        .contextMenu { JobMenu(job: job) }
    }

    @ViewBuilder private var detail: some View {
        if let active = job.activeRun {
            let line = active.status == .queued
                ? "Waits for a free slot"
                : "Running for \(active.seconds(now: model.now).map { Formatting.duration($0) } ?? "a moment")"
                    + (active.trigger == .manual ? ", you started it" : "")
            Text(line).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent).lineLimit(1)
        } else if let last = job.lastRun, last.status.isFailure, job.secretsAllowed != false {
            Button {
                model.showLog(last)
            } label: {
                Text(failedText(last)).font(.system(size: 11)).foregroundStyle(Theme.dangerText).lineLimit(1)
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
        Divider()
        Button("Show Runs") { model.showRuns(jobID: job.id) }
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
