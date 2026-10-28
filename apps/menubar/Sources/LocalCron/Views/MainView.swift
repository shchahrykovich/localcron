import LocalCronKit
import SwiftUI

/// The popover: a header, the tabs (or the editor or a run log in their
/// place), and a footer with the last message.
struct MainView: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.page {
                case .tabs:
                    VStack(spacing: 0) {
                        Picker("", selection: $model.tab) {
                            Text("Jobs").tag(AppModel.Tab.jobs)
                            Text("Runs").tag(AppModel.Tab.runs)
                            Text("Settings").tag(AppModel.Tab.settings)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        switch model.tab {
                        case .jobs: JobsView()
                        case .runs: RunsView()
                        case .settings: SettingsView(perform: perform)
                        }
                    }
                case let .editor(draft):
                    JobEditorView(draft: draft)
                        // A new editor for each job, so the fields start fresh.
                        .id(draft.isNew ? "new" : draft.id)
                case let .log(runID):
                    RunLogView(runID: runID).id(runID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.title3)
            Text(Instance.current.appName).font(.headline)
            Spacer()
            if let status = model.status {
                if status.running > 0 || status.queued > 0 {
                    Text("\(status.running) running" + (status.queued > 0 ? ", \(status.queued) queued" : ""))
                        .font(.caption).foregroundStyle(.blue)
                } else {
                    Text("\(status.enabledJobs) of \(status.jobs) jobs on").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Not running", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(alignment: .top) {
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.messageFailed ? .red : .secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.message = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if let problem = model.serviceNote ?? model.daemonProblem {
                Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(nextText).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
    }

    private var nextText: String {
        guard let next = model.status?.next, let at = ApiDate.parse(next.at) else { return "No run is planned." }
        return "Next: \(next.jobId) \(Formatting.next(at))"
    }
}
