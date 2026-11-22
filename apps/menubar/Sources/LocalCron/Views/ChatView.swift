import AppKit
import LocalCronKit
import SwiftUI

/// The Chat page of the app window, as in Slack: a channel per job on the
/// left; on the right each run of the chosen channel as a post, with its
/// status, a View Log button and the messages it sent (`send_message`),
/// oldest at the top. Only jobs write here; the user reads.
struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let channels = Chat.channels(model.messages, runs: model.allRuns, jobIDs: model.jobs.map(\.id))
        HStack(spacing: 0) {
            ChannelList(channels: channels)
                .frame(width: 230)
            Rectangle().fill(Theme.line).frame(width: 0.5)
            Conversation()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.card)
    }
}

/// "All jobs", then one row per job, the one with the newest run or message
/// first.
private struct ChannelList: View {
    @Environment(AppModel.self) private var model
    let channels: [Chat.Channel]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat").font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 14)
                .frame(height: 52, alignment: .leading)
            Rectangle().fill(Theme.line).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row(nil, title: "All jobs", unread: channels.reduce(0) { $0 + $1.unread },
                        workingCount: channels.filter { $0.working != nil }.count)
                    Text("Jobs").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    if channels.isEmpty {
                        Text("No jobs yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                    }
                    ForEach(channels) { channel in
                        row(channel.jobID, title: channel.jobID, unread: channel.unread, working: channel.working)
                    }
                }
                .padding(8)
            }
        }
        .background(Theme.ground)
    }

    /// A job whose run works now looks as that run does on the Logs page:
    /// the status icon instead of the job's, in a light accent row.
    private func row(_ jobID: String?, title: String, unread: Int, working: Run? = nil, workingCount: Int = 0) -> some View {
        let selected = model.chatJob == jobID
        let workingText = working.map { RunText.line($0, now: model.now).text }
        return Button { model.chatJob = jobID } label: {
            HStack(spacing: 8) {
                Group {
                    if let working {
                        Image(systemName: working.status.symbol).font(.system(size: 13))
                            .foregroundStyle(selected ? Color.white : working.status.color)
                    } else if let jobID, let job = model.job(jobID) {
                        JobGlyph(job: job.job, size: 13)
                    } else {
                        Image(systemName: jobID == nil ? "tray.full" : "number").font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(width: 18)
                .foregroundStyle(selected ? Color.white : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: unread > 0 || selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : unread > 0 ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if workingCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: RunStatus.running.symbol).font(.system(size: 10))
                        Text("\(workingCount)").font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    }
                    .foregroundStyle(selected ? Color.white : Theme.accentSoftText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(selected ? Color.white.opacity(0.3) : Theme.accentSoft, in: Capsule())
                    .help(workingCount == 1 ? "1 job runs now" : "\(workingCount) jobs run now")
                }
                if unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.3) : Theme.unread, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? Theme.accentFill : working != nil ? Theme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(jobID == nil ? "Every run and message, from every job" : workingText.map { "\(title): \($0)" } ?? title)
        .accessibilityLabel([title, workingText, unread > 0 ? "\(unread) new" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The header of the channel, its runs by day, and a note where Slack has
/// the box to write in.
private struct Conversation: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let days = Chat.timeline(model.messages, runs: model.allRuns, jobID: model.chatJob, now: model.now)
        VStack(spacing: 0) {
            header(days)
            Rectangle().fill(Theme.line).frame(height: 0.5)
            if days.isEmpty {
                empty
            } else {
                messages(days)
            }
            footnote
        }
    }

    private func header(_ days: [Chat.Day]) -> some View {
        let job = model.chatJob.flatMap(model.job)
        let groups = days.flatMap(\.groups)
        let runs = groups.filter { $0.run != nil }.count
        let count = groups.reduce(0) { $0 + $1.messages.count }
        return HStack(spacing: 10) {
            if let job {
                JobTile(job: job, ground: Theme.card)
            } else {
                Image(systemName: model.chatJob == nil ? "tray.full" : "number")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Theme.neutralSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.chatJob ?? "All jobs").font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(subtitle(job: job, runs: runs, messages: count)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if count > 0 {
                SmallButton("Remove Messages") {
                    let ids = Chat.messages(model.messages, jobID: model.chatJob).map(\.message.id)
                    Task { await model.removeMessages(ids) }
                }
                .help(model.chatJob == nil ? "Remove every message" : "Remove the messages of \(model.chatJob ?? "")")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func subtitle(job: JobView?, runs: Int, messages: Int) -> String {
        let counts = "\(RunGroups.count(runs)) · " + (messages == 1 ? "1 message" : "\(messages) messages")
        if let job { return "\(job.scheduleText) · \(counts)" }
        if model.chatJob != nil { return "This job no longer exists · \(counts)" }
        return counts
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("No runs yet").font(.system(size: 14, weight: .medium))
            Text("Each run shows here when it starts, with the messages it sends you.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messages(_ days: [Chat.Day]) -> some View {
        // A post is a child of the lazy stack, so it can be scrolled to; a
        // message inside it cannot. A new run or message changes `lastKey`.
        let last = days.last?.groups.last
        let lastKey = last.map { "\($0.id) \($0.messages.count)" }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days) { day in
                        DayLine(title: day.title)
                        ForEach(day.groups) { group in
                            if group.contains(message: model.chatNewFrom) { NewLine().id("new") }
                            GroupView(group: group)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear { scroll(proxy, to: last?.id) }
            .onChange(of: model.chatJob) { scroll(proxy, to: last?.id) }
            .onChange(of: lastKey) { scroll(proxy, to: last?.id) }
        }
    }

    /// To the "New" line when there is one, else to the newest post.
    private func scroll(_ proxy: ScrollViewProxy, to lastGroup: String?) {
        DispatchQueue.main.async {
            if model.chatNewFrom != nil, Chat.messages(model.messages, jobID: model.chatJob)
                .contains(where: { $0.message.id == model.chatNewFrom }) {
                proxy.scrollTo("new", anchor: .top)
            } else if let lastGroup {
                proxy.scrollTo(lastGroup, anchor: .bottom)
            }
        }
    }

    private var footnote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Only jobs write here: each run, and a message when a run needs you (send_message).")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }
}

/// A day's title on a line across the conversation.
private struct DayLine: View {
    let title: String

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

/// The red line above the messages that were unread when the channel opened.
private struct NewLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.failed).frame(height: 1)
            Text("New").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.failed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityLabel("New messages below")
    }
}

/// One run as a post: the job's icon and name, the time and who started
/// it; then its status with a View Log button; then the messages it sent.
private struct GroupView: View {
    @Environment(AppModel.self) private var model
    let group: Chat.Group

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.jobID).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(Formatting.clock(group.at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    if let chip = group.run.flatMap(RunText.chip) {
                        Chip(text: chip, kind: group.run?.trigger == .catchUp ? .accent : .outline)
                    }
                }
                if let run = group.run {
                    RunLine(run: run)
                } else {
                    Text("\(group.runID): the log of this run is deleted")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(group.messages) { message in
                    MessageLine(message: message)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var avatar: some View {
        Group {
            if let job = model.job(group.jobID) {
                JobGlyph(job: job.job, size: 18)
            } else {
                Image(systemName: "questionmark").font(.system(size: 15, weight: .medium))
            }
        }
        .foregroundStyle(Color.primary.opacity(0.75))
        .frame(width: 36, height: 36)
        .background(Theme.neutralSoft, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

/// A run's status in a light box: "Succeeded in 2 s", "Failed with exit
/// code 1 after 4 min", "Working for 3 min", then its tokens and View Log.
private struct RunLine: View {
    @Environment(AppModel.self) private var model
    let run: Run

    var body: some View {
        let line = RunText.line(run, now: model.now)
        HStack(spacing: 8) {
            Image(systemName: run.shownStatus.symbol).font(.system(size: 13)).foregroundStyle(run.shownStatus.color)
            Text(line.text).font(.system(size: 12, weight: line.tone == .plain ? .regular : .medium))
                .foregroundStyle(line.tone.color).lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let usage = run.usage {
                Text(Formatting.tokens(usage.total)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .help(RunText.tokens(usage))
            }
            SmallButton("View Log") { model.showLog(run) }
                .help("The output of \(run.id)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(run.shownStatus.isFailure || line.tone == .danger ? Theme.dangerRow
                    : run.status.isFinished ? Theme.field.opacity(0.5) : Theme.accentSoft,
                    in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 640, alignment: .leading)
        .contextMenu {
            Button("View Log") { model.showLog(run) }
            Button("Reveal Log in Finder") { model.revealLog(run) }
            if let job = model.job(run.jobId) {
                Button("Run \(run.jobId) Again") { Task { await model.runNow(job) } }
            }
        }
    }
}

/// One message. Under the pointer it gets a light background and the
/// buttons Copy, Show Log and Remove at its top right, as in Slack.
private struct MessageLine: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @State private var hovering = false

    var body: some View {
        MessageBody(message.text, colors: .init(link: NSColor(Theme.accent), box: Theme.field, line: Theme.line))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(hovering ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, -6)
            .overlay(alignment: .topTrailing) {
                if hovering { actions.offset(y: -14) }
            }
            .zIndex(hovering ? 1 : 0)
            .onHover { hovering = $0 }
            .help(ApiDate.parse(message.at).map { Formatting.clock($0) } ?? "")
            .contextMenu {
                Button("Copy Text") { model.copy(message.text) }
                Button("Show Log") { model.showLog(runID: message.runId) }
                Divider()
                Button("Remove") { Task { await model.removeMessages([message.id]) } }
            }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "doc.on.doc", help: "Copy the text", size: 24) { model.copy(message.text) }
            IconButton(symbol: "doc.text", help: "Show the log of \(message.runId)", size: 24) {
                model.showLog(runID: message.runId)
            }
            IconButton(symbol: "trash", help: "Remove", size: 24) { Task { await model.removeMessages([message.id]) } }
        }
        .padding(2)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}
