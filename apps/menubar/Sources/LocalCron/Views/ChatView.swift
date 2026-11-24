import AppKit
import LocalCronKit
import SwiftUI

/// The Chat page of the app window, as in Slack: a channel per job on the
/// left; on the right each run of the chosen channel as a post, with its
/// status, a View Log button and the messages it sent (`send_message`),
/// oldest at the top, and the conversation with the manager, a Claude
/// session the user writes to in the box at the bottom (ManagerStore).
struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let channels = Chat.channels(model.messages, runs: model.allRuns, jobIDs: model.jobs.map(\.id), order: model.chatOrder)
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

/// "All jobs", then one row per job, in the order the user chose in the
/// menu beside "Jobs": the newest activity first by default. With another
/// order, each row shows its value: the last run, the runs or the messages.
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
                    sectionHeader
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    if channels.isEmpty {
                        Text("No jobs yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                    }
                    ForEach(channels) { channel in
                        row(channel.jobID, title: channel.jobID, unread: channel.unread, working: channel.working,
                            value: value(channel))
                    }
                }
                .padding(8)
            }
        }
        .background(Theme.ground)
    }

    private var sectionHeader: some View {
        @Bindable var model = model
        return HStack(spacing: 4) {
            Text(model.chatOrder == .activity ? "Jobs" : "Jobs by \(model.chatOrder.rawValue.lowercased())")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Sort Jobs By", selection: $model.chatOrder) {
                    ForEach(Chat.Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Sort the jobs")
        }
        .frame(height: 22)
    }

    /// What a row shows on its right for the chosen order.
    private func value(_ channel: Chat.Channel) -> String? {
        switch model.chatOrder {
        case .activity, .name: nil
        case .lastRun: channel.lastRun.map { Chat.shortAge($0, now: model.now) } ?? "–"
        case .runs: "\(channel.runs)"
        case .messages: "\(channel.messages)"
        }
    }

    /// A job whose run works now looks as that run does on the Logs page:
    /// the status icon instead of the job's, in a light accent row.
    private func row(_ jobID: String?, title: String, unread: Int, working: Run? = nil, workingCount: Int = 0,
                     value: String? = nil) -> some View {
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
                if let value {
                    Text(value).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                }
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

/// The channel as in Slack: a header with a search field, the posts by day
/// under a date that stays at the top while it scrolls, and the box to write
/// to the manager at the bottom.
private struct Conversation: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        let talk = model.manager.entries(model.chatJob)
        let days = Chat.timeline(model.messages, runs: model.allRuns, talk: talk, jobID: model.chatJob, query: query,
                                 now: model.now)
        VStack(spacing: 0) {
            header(days)
            Rectangle().fill(Theme.line).frame(height: 0.5)
            if days.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                noMatch
            } else {
                posts(days)
            }
            Composer()
        }
        .onChange(of: model.chatJob) { query = "" }
    }

    private var name: String { model.chatJob ?? "All jobs" }

    private func header(_ days: [Chat.Day]) -> some View {
        let job = model.chatJob.flatMap(model.job)
        let groups = days.flatMap(\.groups)
        let count = Chat.messages(model.messages, jobID: model.chatJob).count
        let talking = !model.manager.entries(model.chatJob).isEmpty
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
                Text(name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Text(subtitle(job: job, groups: groups)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let job { runButtons(job) }
            SearchBox(prompt: "Search \(name)", text: $query, focused: $searching)
                .frame(width: 230)
            Menu {
                if let job {
                    runMenu(job)
                    Divider()
                }
                Button("New Conversation with the Manager") { model.manager.startOver(jobID: model.chatJob) }
                    .disabled(!talking)
                Button(model.chatJob == nil ? "Remove Every Message from Jobs" : "Remove the Messages of \(name)") {
                    let ids = Chat.messages(model.messages, jobID: model.chatJob).map(\.message.id)
                    Task { await model.removeMessages(ids) }
                }
                .disabled(count == 0)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /// The buttons next to the search field: Open Terminal while the job
    /// runs in a console, else Run Now and Run Now, Instead of its next time.
    @ViewBuilder private func runButtons(_ job: JobView) -> some View {
        if let active = job.activeRun {
            if active.console != nil {
                SmallButton("Open Terminal") { model.openTerminal(active) }
                    .help("Its Claude Code console: watch it and type into it")
            }
        } else {
            HStack(spacing: 6) {
                if let next = ApiDate.parse(job.nextRun) {
                    SmallButton("Run Now, Instead of \(Formatting.next(next, now: model.now))") {
                        Task { await model.runNow(job, early: true) }
                    }
                    .help("This run takes the place of the next scheduled run; the schedule goes on after it")
                }
                SmallButton("Run Now") { Task { await model.runNow(job) } }
                    .help("An extra run; the next scheduled run stays")
            }
            .fixedSize()
        }
    }

    /// The same commands in the "…" menu, with Stop while the job runs.
    @ViewBuilder private func runMenu(_ job: JobView) -> some View {
        if let active = job.activeRun {
            if active.console != nil {
                Button("Open Terminal") { model.openTerminal(active) }
            }
            Button("Stop \(active.id)") { Task { await model.cancel(active) } }
        } else {
            Button("Run Now") { Task { await model.runNow(job) } }
            if let next = ApiDate.parse(job.nextRun) {
                Button("Run Now, Instead of \(Formatting.next(next, now: model.now))") {
                    Task { await model.runNow(job, early: true) }
                }
            }
        }
    }

    private func subtitle(job: JobView?, groups: [Chat.Group]) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return groups.count == 1 ? "1 post has “\(q)”" : "\(groups.count) posts have “\(q)”" }
        let runs = groups.filter { $0.run != nil }.count
        let messages = groups.reduce(0) { $0 + $1.messages.count }
        let counts = "\(RunGroups.count(runs)) · " + (messages == 1 ? "1 message" : "\(messages) messages")
        if let job { return "\(job.scheduleText) · \(counts)" }
        if model.chatJob != nil { return "This job no longer exists · \(counts)" }
        return counts
    }

    private var noMatch: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.tertiary)
            Text("Nothing has “\(query.trimmingCharacters(in: .whitespaces))”").font(.system(size: 14, weight: .medium))
            Text("The search looks in run results, messages and the conversation with the manager.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The start of the channel, as Slack shows above the first post.
    private var intro: some View {
        let job = model.chatJob.flatMap(model.job)
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let job {
                    JobGlyph(job: job.job, size: 24)
                } else {
                    Image(systemName: "tray.full").font(.system(size: 22))
                }
            }
            .foregroundStyle(Color.primary.opacity(0.75))
            .frame(width: 52, height: 52)
            .background(Theme.neutralSoft, in: RoundedRectangle(cornerRadius: 10))
            Text(name).font(.system(size: 20, weight: .bold)).padding(.top, 4)
            Text(model.chatJob == nil
                ? "Every run of every job is a post here, with the messages it sends you. Write below to ask the manager about your jobs."
                : "Each run of \(name) is a post here, with the messages it sends you. Write below to ask the manager about a run, change the job or run it again.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func posts(_ days: [Chat.Day]) -> some View {
        let last = days.last?.groups.last
        let lastKey = last.map { "\($0.id) \($0.messages.count) \($0.talk.count) \($0.talk.last?.text.count ?? 0)" }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if query.isEmpty { intro }
                    ForEach(days) { day in
                        Section {
                            // The line through the date, under its pill: it
                            // scrolls away while the pill stays on top.
                            Rectangle().fill(Theme.line).frame(height: 0.5)
                                .offset(y: -DayPill.height / 2)
                            ForEach(day.groups) { group in
                                if group.contains(message: model.chatNewFrom) { NewLine().id("new") }
                                PostView(group: group, query: query)
                            }
                        } header: {
                            DayPill(title: day.title)
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
}

/// The search field of the channel header. ⌘F puts the cursor in it.
private struct SearchBox: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
                .focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused.wrappedValue ? Theme.accent.opacity(0.6) : Theme.line,
                                                                lineWidth: focused.wrappedValue ? 1 : 0.5))
        .help("Search this channel")
    }
}

/// The date above the posts of a day. It stays at the top while its posts
/// scroll under it.
private struct DayPill: View {
    static let height: CGFloat = 26
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .padding(.top, 10)
    }
}

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

/// One post: a run with its messages, or what the user or the manager
/// wrote. A post that follows one by the same author shows no picture and
/// name, only its time on hover, as in Slack. The whole row lights up under
/// the pointer, with its actions at the top right.
private struct PostView: View {
    @Environment(AppModel.self) private var model
    let group: Chat.Group
    let query: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if group.continues {
                Text(Formatting.clock(group.at)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.top, 3)
                    .opacity(hovering ? 1 : 0)
            } else {
                avatar.padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !group.continues { title }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, group.continues ? 3 : 8)
        .padding(.bottom, 4)
        .background(hovering ? Theme.rowHover : .clear)
        .overlay(alignment: .topTrailing) {
            if hovering { actions.padding(.trailing, 16).offset(y: -10) }
        }
        .zIndex(hovering ? 1 : 0)
        .onHover { hovering = $0 }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch group.author {
            case .job:
                Text(group.jobID).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
            case .user:
                Text("You").font(.system(size: 13.5, weight: .bold))
            case .manager:
                Text("Manager").font(.system(size: 13.5, weight: .bold))
                Chip(text: "Claude", kind: .accent)
            }
            Text(Formatting.clock(group.at)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if let chip = group.run.flatMap(RunText.chip) {
                Chip(text: chip, kind: group.run?.trigger == .catchUp ? .accent : .outline)
            }
        }
    }

    @ViewBuilder private var avatar: some View {
        switch group.author {
        case .job:
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
            .accessibilityHidden(true)
        case .user:
            Image(systemName: "person.fill").font(.system(size: 17))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        case .manager:
            Image(systemName: "sparkles").font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var content: some View {
        switch group.author {
        case .job:
            if let run = group.run {
                RunAttachment(run: run, query: query)
            } else {
                Text("\(group.runID): the log of this run is deleted")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(group.messages) { message in
                MessageLine(message: message, query: query)
            }
        case .user, .manager:
            ForEach(group.talk) { entry in
                EntryView(entry: entry, query: query)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 0) {
            if let run = group.run {
                IconButton(symbol: "bubble.left", help: "Ask the manager about \(run.id)", size: 24) { ask(about: run) }
                IconButton(symbol: "doc.text", help: "The output of \(run.id)", size: 24) { model.showLog(run) }
                if run.status.isFinished, let job = model.job(run.jobId) {
                    IconButton(symbol: "arrow.clockwise", help: "Run \(run.jobId) again", size: 24) {
                        Task { await model.runNow(job) }
                    }
                }
            } else if group.author != .job {
                IconButton(symbol: "doc.on.doc", help: "Copy the text", size: 24) {
                    model.copy(group.talk.filter { $0.kind == .user || $0.kind == .agent }.map(\.text).joined(separator: "\n\n"))
                }
            }
        }
        .padding(2)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }

    private func ask(about run: Run) {
        let key = Manager.key(model.chatJob)
        model.manager.aboutRun[key] = run.id
        model.manager.focusRequest += 1
    }
}

/// A run as a Slack attachment: a bar in the color of its status, its result
/// in one or a few lines, its tokens and a View Log button.
private struct RunAttachment: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let query: String

    var body: some View {
        let line = RunText.line(run, now: model.now)
        let failed = run.shownStatus.isFailure || line.tone == .danger
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(failed ? Theme.failed : run.status.isFinished ? run.shownStatus.color.opacity(0.75) : Theme.accent)
                .frame(width: 4)
            Image(systemName: run.shownStatus.symbol).font(.system(size: 13)).foregroundStyle(run.shownStatus.color)
                .padding(.top, 1)
            Text(highlighted(line.text, query))
                .font(.system(size: 13, weight: line.tone == .plain ? .regular : .medium))
                .foregroundStyle(line.tone == .plain ? Color.primary.opacity(0.85) : line.tone.color)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let usage = run.usage {
                Text(Formatting.tokens(usage.total)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .help(RunText.tokens(usage))
                    .padding(.top, 2)
            }
            SmallButton("View Log") { model.showLog(run) }
                .help("The output of \(run.id)")
        }
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 720, alignment: .leading)
        .contextMenu {
            Button("Ask the Manager About This Run") {
                model.manager.aboutRun[Manager.key(model.chatJob)] = run.id
                model.manager.focusRequest += 1
            }
            Button("View Log") { model.showLog(run) }
            Button("Reveal Log in Finder") { model.revealLog(run) }
            if let job = model.job(run.jobId) {
                Button("Run \(run.jobId) Again") { Task { await model.runNow(job) } }
            }
        }
    }
}

/// `text` with every place it has `query` marked, as the search found it.
private func highlighted(_ text: String, _ query: String) -> AttributedString {
    var out = AttributedString(text)
    for range in MessageMarkdown.matches(of: query, in: text) {
        guard let r = Range(range, in: text),
              let lower = AttributedString.Index(r.lowerBound, within: out),
              let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
        out[lower ..< upper].backgroundColor = Color(nsColor: MessageMarkdown.highlightColor)
    }
    return out
}

@MainActor private var messageColors: MessageBody.Colors { MessageBody.Colors(link: NSColor(Theme.accent), box: Theme.field, line: Theme.line) }

private struct MessageLine: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let query: String
    @State private var hovering = false

    var body: some View {
        MessageBody(message.text, colors: messageColors, highlight: query)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
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
            IconButton(symbol: "trash", help: "Remove", size: 24) { Task { await model.removeMessages([message.id]) } }
        }
        .padding(2)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

/// One entry of the conversation with the manager.
private struct EntryView: View {
    @Environment(AppModel.self) private var model
    let entry: ManagerEntry
    let query: String

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .leading, spacing: 4) {
                if let runID = entry.runID {
                    Button { model.showLog(runID: runID) } label: {
                        Label("About \(runID)", systemImage: "arrow.turn.down.right")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.accentSoftText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Show the log of \(runID)")
                }
                markdown(entry.text)
            }
        case .agent:
            markdown(entry.text)
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: toolSymbol).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(entry.status == "failed" ? Theme.failed : .secondary)
                    .frame(width: 12)
                Text(entry.text).font(.system(size: 12, design: entry.text.hasPrefix("$ ") ? .monospaced : .default))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .help(entry.text)
        case .permission:
            PermissionCard(entry: entry)
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.failed)
                    .padding(.top, 1)
                markdown(entry.text)
            }
        }
    }

    private var toolSymbol: String {
        switch entry.status {
        case "completed": "checkmark"
        case "failed": "xmark"
        default: "gearshape"
        }
    }

    private func markdown(_ text: String) -> some View {
        MessageBody(text, colors: messageColors, highlight: query)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 760, alignment: .leading)
    }
}

/// The manager asks to use a tool that changes something: the user answers
/// with one of the buttons, as in a Slack app's message.
private struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let entry: ManagerEntry

    var body: some View {
        let waiting = model.manager.isWaiting(entry)
        VStack(alignment: .leading, spacing: 8) {
            MessageBody(entry.text, colors: messageColors)
                .fixedSize(horizontal: false, vertical: true)
            if waiting {
                HStack(spacing: 6) {
                    ForEach(entry.options, id: \.id) { option in
                        SmallButton(option.name, prominent: option.kind == "allow_once") {
                            model.manager.answer(entry, with: option)
                        }
                    }
                }
            } else {
                Label(entry.choice ?? "Not answered", systemImage: answerSymbol)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(waiting ? Theme.accentSoft.opacity(0.6) : Theme.field.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(waiting ? Theme.accent.opacity(0.4) : Theme.line, lineWidth: 0.5))
    }

    private var answerSymbol: String {
        guard let choice = entry.choice, let option = entry.options.first(where: { $0.name == choice }) else { return "minus.circle" }
        return option.allows ? "checkmark.circle" : "xmark.circle"
    }
}

/// The box to write to the manager, where Slack has its message box. Return
/// sends; Option-Return starts a new line.
private struct Composer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let manager = model.manager
        let key = Manager.key(model.chatJob)
        let working = manager.isWorking(model.chatJob)
        let draft = manager.drafts[key] ?? ""
        VStack(alignment: .leading, spacing: 6) {
            if let runID = manager.aboutRun[key] {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .semibold))
                    Text("About \(runID)").font(.system(size: 11.5, weight: .medium))
                    Button { manager.aboutRun[key] = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Not about this run")
                }
                .foregroundStyle(Theme.accentSoftText)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accentSoft, in: Capsule())
            }
            TextField(placeholder, text: Binding(get: { manager.drafts[key] ?? "" }, set: { manager.drafts[key] = $0 }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1 ... 8)
                .focused($focused)
                .onSubmit(send)
            HStack(spacing: 8) {
                if working {
                    ProgressView().controlSize(.small)
                    Text("The manager is working…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("The manager is a Claude session with the LocalCron tools. It uses them without asking; other tools ask you first.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if working {
                    Button { manager.stop(jobID: model.chatJob) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 22)
                            .background(Theme.failed, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Stop the answer")
                } else {
                    let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(action: send) {
                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                            .foregroundStyle(empty ? Color.secondary : .white)
                            .frame(width: 26, height: 22)
                            .background(empty ? Theme.field : Theme.accentFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .help("Send (Return)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Theme.accent.opacity(0.55) : Theme.neutralLine,
                                                                lineWidth: focused ? 1.2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .onChange(of: manager.focusRequest) { focused = true }
    }

    private var placeholder: String {
        model.chatJob.map { "Message the manager about \($0)" } ?? "Message the manager about your jobs"
    }

    private func send() {
        let key = Manager.key(model.chatJob)
        let text = model.manager.drafts[key] ?? ""
        model.manager.send(text, jobID: model.chatJob, model: model)
        focused = true
    }
}
