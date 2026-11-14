import AppKit
import LocalCronKit
import SwiftUI

/// The window that asks the user to allow a job to read its secrets. It
/// shows what changed since the last OK, what Claude thinks of the job, and
/// everything the job runs. Cancel is the safe answer: Escape and closing the
/// window mean Cancel, and Return does nothing.
@MainActor
final class SecretApprovalWindow: NSObject, NSWindowDelegate {
    private static var current: SecretApprovalWindow?
    /// Reviews by what they reviewed, so the window opened again for the same
    /// job does not ask Claude again.
    private static var reviews: [String: SecretReview] = [:]

    private let window: NSWindow
    private let review: SecretReviewState
    private var continuation: CheckedContinuation<Bool, Never>?

    /// True when the user pressed Allow. Touch ID comes after, in the caller.
    static func ask(_ approval: SecretApproval) async -> Bool {
        current?.finish(false)
        let w = SecretApprovalWindow(approval)
        current = w
        return await withCheckedContinuation { c in
            w.continuation = c
            w.show()
        }
    }

    private init(_ approval: SecretApproval) {
        let key = Self.key(approval)
        review = SecretReviewState(cached: Self.reviews[key])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Allow Secrets"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 420)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SecretApprovalView(
            approval: approval, review: review,
            onCancel: { [weak self] in self?.finish(false) },
            onAllow: { [weak self] in self?.finish(true) }))
        window.setContentSize(NSSize(width: 660, height: 680))
        review.start(approval) { Self.reviews[key] = $0 }
    }

    private static func key(_ approval: SecretApproval) -> String {
        let scope = (try? Api.encoder.encode(SecretScope(approval.job))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return approval.job.id + "\n" + scope + "\n" + (approval.before?.allowedAt ?? "")
    }

    private func show() {
        window.center()
        DockPresence.windowWillShow()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ allowed: Bool) {
        guard let c = continuation else { return }
        continuation = nil
        window.delegate = nil
        window.close()
        if Self.current === self { Self.current = nil }
        c.resume(returning: allowed)
    }

    func windowWillClose(_ notification: Notification) {
        finish(false)
    }
}

/// Claude's review of one job, filled in when `claude -p` ends.
@MainActor
@Observable
final class SecretReviewState {
    enum Phase: Equatable {
        case running
        case done(SecretReview)
        case failed(SecretReviewError)
    }

    var phase: Phase

    init(cached: SecretReview?) {
        phase = cached.map(Phase.done) ?? .running
    }

    func start(_ approval: SecretApproval, save: @escaping @MainActor (SecretReview) -> Void) {
        guard phase == .running else { return }
        Task.detached(priority: .userInitiated) {
            let result = SecretReviewer.review(approval)
            await MainActor.run {
                switch result {
                case .success(let review):
                    save(review)
                    self.phase = .done(review)
                case .failure(let error):
                    self.phase = .failed(error)
                }
            }
        }
    }
}

struct SecretApprovalView: View {
    let approval: SecretApproval
    let review: SecretReviewState
    let onCancel: () -> Void
    let onAllow: () -> Void
    @State private var showJob: Bool

    init(approval: SecretApproval, review: SecretReviewState, onCancel: @escaping () -> Void, onAllow: @escaping () -> Void) {
        self.approval = approval
        self.review = review
        self.onCancel = onCancel
        self.onAllow = onAllow
        // A new job has no change to read: show the whole job at once.
        _showJob = State(initialValue: approval.changes.isEmpty)
    }

    private var danger: Bool {
        if case .done(let r) = review.phase { return r.verdict == .danger }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    secretsSection
                    if !approval.changes.isEmpty { changesSection }
                    reviewSection
                    jobSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .background(Theme.ground)
        .tint(Theme.accentFill)
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.warningText)
                .frame(width: 40, height: 40)
                .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(approval.title).font(.title3.weight(.semibold))
                Text(approval.subtitle()).foregroundStyle(.secondary)
                Text((approval.job.dir as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.mono).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var secretsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Secrets it gets")
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(approval.secrets, id: \.variable) { s in
                        HStack(spacing: 8) {
                            Text("$" + s.variable).font(Theme.mono.weight(.semibold))
                            Text("from the secret").foregroundStyle(.secondary)
                            Chip(text: s.secret, kind: .warning)
                        }
                    }
                }
            }
        }
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "What changed since you allowed it") {
                HStack(spacing: 10) {
                    legend("removed", Theme.dangerSoft, Theme.dangerText)
                    legend("added", Theme.successSoft, Theme.successText)
                }
            }
            Card {
                ForEach(Array(approval.changes.enumerated()), id: \.element.id) { index, change in
                    if index > 0 { RowDivider() }
                    ChangeRow(change: change).padding(12)
                }
            }
        }
    }

    private func legend(_ text: String, _ ground: Color, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(ground, in: RoundedRectangle(cornerRadius: 3))
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("What Claude thinks")
            Card(padding: 12) {
                switch review.phase {
                case .running:
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude is reading the job…")
                            Text("It can read files in the job's folder, but not run anything. It takes 10 to 60 seconds. You can decide without it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .failed(let error):
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                case .done(let r):
                    ReviewResult(review: r)
                }
            }
        }
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $showJob) {
                Card(padding: 12) {
                    Text(approval.details)
                        .font(Theme.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            } label: {
                Text("Everything the job runs").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("The job can do anything with these values, also send them elsewhere. Allow it only if you understand what it runs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(action: onAllow) {
                Label(danger ? "Allow Anyway…" : "Allow with Touch ID…", systemImage: "touchid")
            }
            .tint(danger ? Theme.failed : Theme.accentFill)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// One changed field. A command or a prompt shows as a word diff; a short
/// value shows as before and now.
private struct ChangeRow: View {
    let change: SecretChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(change.field).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if change.long {
                Text(diffText)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            } else {
                value("Before", change.old, Theme.dangerText, struck: true)
                value("Now", change.new, Theme.successText, struck: false)
            }
        }
    }

    private func value(_ label: String, _ text: String, _ color: Color, struck: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            if text.isEmpty {
                Text("not set").font(.caption).italic().foregroundStyle(.secondary)
            } else {
                Text(text).font(Theme.mono).foregroundStyle(color).strikethrough(struck, color: color).textSelection(.enabled)
            }
        }
    }

    private var diffText: AttributedString {
        var out = AttributedString()
        for piece in TextDiff.shortened(change.diff) {
            var part = AttributedString(piece.text)
            switch piece {
            case .same:
                part.foregroundColor = .secondary
            case .removed:
                part.foregroundColor = Theme.dangerText
                part.backgroundColor = Theme.dangerSoft
                part.strikethroughStyle = .single
            case .added:
                part.foregroundColor = Theme.successText
                part.backgroundColor = Theme.successSoft
            }
            out += part
        }
        return out
    }
}

private struct ReviewResult: View {
    let review: SecretReview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.headline).foregroundStyle(color)
            }
            Text(review.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(review.risks) { risk in
                HStack(alignment: .top, spacing: 8) {
                    Chip(text: risk.level.rawValue, kind: kind(risk.level))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(risk.title).fontWeight(.medium)
                        Text(risk.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Claude can be wrong, and the job's text can try to mislead it. You decide.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch review.verdict {
        case .safe: "No risks found"
        case .caution: "Check this before you allow it"
        case .danger: "Dangerous: this job can leak a secret or do harm"
        }
    }

    private var icon: String {
        switch review.verdict {
        case .safe: "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch review.verdict {
        case .safe: Theme.successText
        case .caution: Theme.warningText
        case .danger: Theme.dangerText
        }
    }

    private func kind(_ level: SecretReview.Risk.Level) -> Chip.Kind {
        switch level {
        case .high: .danger
        case .medium: .warning
        case .low: .neutral
        }
    }
}
