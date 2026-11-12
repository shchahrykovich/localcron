import AppKit
import LocalCronKit
import SwiftUI

/// The Messages tab: what runs told the user, newest first, by day. A job
/// sends one only when something needs the user, so most days have none.
struct MessagesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.messages.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("No messages").font(.system(size: 13, weight: .medium))
                Text("A job sends one only when something needs you.\nMost runs send none.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(MessageDay.byDay(model.messages, now: model.now)) { day in
                        VStack(spacing: 6) {
                            SectionLabel(text: day.title) { Text(day.messages.count == 1 ? "1 message" : "\(day.messages.count) messages") }
                            Card {
                                ForEach(Array(day.messages.enumerated()), id: \.element.id) { i, message in
                                    if i > 0 { RowDivider() }
                                    MessageRow(message: message, isNew: model.newMessageIDs.contains(message.id) || !message.read)
                                }
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

/// The messages of one day, newest first.
struct MessageDay: Identifiable {
    var day: Date
    var title: String
    var messages: [Message]
    var id: Date { day }

    static func byDay(_ messages: [Message], now: Date, calendar: Calendar = .current) -> [MessageDay] {
        var days: [MessageDay] = []
        for message in messages {
            guard let at = ApiDate.parse(message.at) else { continue }
            let day = calendar.startOfDay(for: at)
            if let i = days.firstIndex(where: { $0.day == day }) {
                days[i].messages.append(message)
            } else {
                days.append(MessageDay(day: day, title: Formatting.dayTitle(day, now: now, calendar: calendar), messages: [message]))
            }
        }
        return days.sorted { $0.day > $1.day }
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let isNew: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(isNew ? Theme.unread : .clear).frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityLabel(isNew ? "new" : "")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let job = model.job(message.jobId) {
                        JobGlyph(job: job.job, size: 12).foregroundStyle(.secondary)
                    }
                    Text(message.jobId).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let reported = model.run(message.runId)?.reported {
                        Chip(text: reported.status == .error ? "Reported an error" : "Reported success",
                             kind: reported.status == .error ? .danger : .success)
                            .help(reported.note)
                    }
                    Spacer(minLength: 4)
                    if let at = ApiDate.parse(message.at) {
                        Text(Formatting.clock(at)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(message.text)
                    .font(.system(size: 12, weight: isNew ? .medium : .regular))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    LinkButton("Show Log") { model.showLog(runID: message.runId) }
                        .help("The output of \(message.runId)")
                    LinkButton("Remove") { Task { await model.removeMessage(message) } }
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contextMenu {
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            Button("Show Log") { model.showLog(runID: message.runId) }
            Divider()
            Button("Remove") { Task { await model.removeMessage(message) } }
        }
    }
}
