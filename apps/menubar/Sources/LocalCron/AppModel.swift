import AppKit
import LocalAuthentication
import LocalCronKit
import Observation
import ServiceManagement

/// Everything the window shows. Jobs and runs live in the daemon; this
/// model only mirrors them.
@MainActor
@Observable
final class AppModel {
    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(Updater.Release)
        case downloading(Updater.Release)
        case failed(String)
    }

    enum Tab: String, CaseIterable, Hashable {
        case jobs = "Jobs", runs = "Runs", messages = "Messages", secrets = "Secrets"
    }

    /// The Runs tab as a list, as a month, or as the tokens agents used.
    enum RunsMode: String, CaseIterable, Hashable {
        case list = "List", calendar = "Calendar", usage = "Usage"
    }

    /// What the window shows in place of the tabs.
    enum Page: Equatable {
        case tabs
        case editor(JobDraft)
        case secretEditor(SecretDraft)
    }

    /// The tabs of the Runs window: the calendar, or every log.
    enum RunsWindowTab: String, CaseIterable, Hashable {
        case calendar = "Calendar", logs = "Logs"
    }

    let client = DaemonClient()
    var status: StatusResult?
    var jobs: [JobView] = []
    var runs: [Run] = []
    var config: Config?
    /// Names and descriptions; the app never has a value after it sent it.
    var secrets: [SecretInfo] = []
    var daemonProblem: String?
    var serviceNote: String?
    var update: UpdateState = .idle
    var message: String?
    var messageFailed = false
    /// The last result of a Coding agents button, shown under that button in
    /// Settings. `at` makes a second click with the same result visible too.
    var agentResult: (action: AppMenu.Action, feedback: Feedback, at: Date)?
    var busy = false
    var tab: Tab = .jobs {
        didSet { if tab == .messages { Task { await markMessagesSeen() } } }
    }
    var page: Page = .tabs
    /// Messages from runs, newest first.
    var messages: [Message] = []
    /// Messages that were unread when the user opened the tab: they stay
    /// marked as new until the popover closes.
    var newMessageIDs: Set<UInt64> = []
    var runsMode: RunsMode = .list
    var runFilter: RunFilter = .all
    /// The Runs tab shows only jobs whose id contains this.
    var runJobFilter = ""
    /// The next times of each job that is on, for the Today strip and the
    /// calendars, from each job's next run on: a time a run early took is
    /// left out. The schedule times are read at most once a minute.
    var planned: [String: [Date]] {
        let next = jobs.reduce(into: [String: Date]()) { out, job in
            if let at = job.nextRun.flatMap(ApiDate.parse) { out[job.id] = at }
        }
        return PlannedTimes.from(scheduleTimes, next: next)
    }
    private var scheduleTimes: [String: [Date]] = [:]
    private var plannedFor: [String: String] = [:]
    private var plannedAt = Date.distantPast
    /// Many more runs than `runs`, for the calendars and the Logs tab.
    /// Loaded while one is shown.
    var history: [Run] = []
    /// The Runs window: its tab, the run whose log the Logs tab shows, and
    /// the filters of its list.
    var runsWindowTab: RunsWindowTab = .calendar
    var logRunID: String?
    var logFilter: RunFilter = .all
    var logJobFilter = ""
    /// The Usage view: how far back, which tokens, and one job or all.
    var usagePeriod: UsagePeriod = .month
    var usageMetric: TokenMetric = .all
    var usageJob: String?
    /// The menu bar icon (Settings, General).
    var iconStyle = IconStyle.saved(UserDefaults.standard.string(forKey: IconStyle.defaultsKey)) {
        didSet { UserDefaults.standard.set(iconStyle.rawValue, forKey: IconStyle.defaultsKey) }
    }
    var iconColor = UserDefaults.standard.object(forKey: IconStyle.colorKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(iconColor, forKey: IconStyle.colorKey) }
    }
    /// Failed runs the user hid with Dismiss: no red mark for them.
    var dismissedRuns = Set(UserDefaults.standard.stringArray(forKey: DismissedFailures.defaultsKey) ?? []) {
        didSet { UserDefaults.standard.set(dismissedRuns.sorted(), forKey: DismissedFailures.defaultsKey) }
    }
    /// Set by StatusItemController: they open its windows.
    var openSettings: (SettingsPage?) -> Void = { _ in }
    var openWeek: () -> Void = {}
    /// Ticks every 30 s, so times such as "in 20 min" stay right.
    var now = Date()
    /// The popover is open: poll often. With unread messages it opens at
    /// the Messages tab, so what needs the user comes first.
    var windowOpen = false {
        didSet {
            if windowOpen && !oldValue {
                if unreadMessages > 0, page == .tabs {
                    tab = .messages
                } else if !failedJobs.isEmpty, page == .tabs {
                    tab = .jobs
                }
                pollNow()
            }
            if !windowOpen { newMessageIDs = [] }
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var wakeUp: CheckedContinuation<Void, Never>?

    static let daemonPlist = "\(Instance.current.daemonLabel).plist"
    private let daemonService = SMAppService.agent(plistName: AppModel.daemonPlist)

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var inBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    var running: Bool { status != nil }
    /// Scheduled runs do not start.
    var paused: Bool { status?.paused ?? false }
    /// Queued and running runs: at most one per job.
    var activeRuns: [Run] { jobs.compactMap(\.activeRun) }
    var statusIcon: StatusIcon { StatusIcon(status: status, jobs: jobs, dismissed: dismissedRuns) }
    /// Jobs whose last run failed, not dismissed, and not because they wait
    /// for the user's OK (the waiting banner says that).
    var failedJobs: [JobView] {
        DismissedFailures.unseen(jobs, dismissed: dismissedRuns).filter { $0.secretsAllowed != false }
    }

    /// Hides the red mark until a job fails again. The runs stay in Runs.
    func dismissFailures() {
        dismissedRuns.formUnion(DismissedFailures.ids(of: failedJobs))
    }
    var unreadMessages: Int { status?.unreadMessages ?? 0 }

    // MARK: Lifecycle

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        registerDaemon()
        if inBundle, let problem = OpenAtLogin().turnOnAtFirstLaunch() { say(problem, failed: true) }
        refreshTask = Task { [weak self] in
            await self?.registerAgainIfStale()
            while !Task.isCancelled {
                await self?.refresh()
                // Every 3 s while the window is open, every 30 s otherwise.
                let open = self?.windowOpen ?? false
                await self?.sleep(seconds: open ? 3 : 30)
            }
        }
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
                    await self?.checkForUpdates(manual: false)
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// A sleep that `pollNow` ends early.
    private func sleep(seconds: Double) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.pollNow()
        }
        await withCheckedContinuation { cont in wakeUp = cont }
        timer.cancel()
    }

    /// Refresh now instead of at the next poll.
    func pollNow() {
        let cont = wakeUp
        wakeUp = nil
        cont?.resume()
    }

    /// Start the daemon at login, as a LaunchAgent inside the bundle.
    func registerDaemon() {
        guard inBundle else {
            serviceNote = "Running outside an app bundle: start \(Instance.current.daemonProgram) yourself."
            return
        }
        if let problem = Instance.currentProblem ?? Instance.current.bundleProblem(Bundle.main.bundleURL) {
            serviceNote = problem
            return
        }
        let approval = "Allow \(Instance.current.appName) in System Settings → General → Login Items."
        switch daemonService.status {
        case .enabled:
            serviceNote = nil
        case .requiresApproval:
            serviceNote = approval
        default:
            do {
                try daemonService.register()
                serviceNote = daemonService.status == .requiresApproval ? approval : nil
            } catch {
                serviceNote = "Could not start the daemon: \(error.localizedDescription)"
            }
        }
    }

    /// The daemon does not answer although it is registered: scripts/install.sh
    /// removed its job, or an ad-hoc rebuild is refused for a while. See
    /// DaemonRestart.
    private func registerAgainIfStale() async {
        guard inBundle, daemonService.status == .enabled else { return }
        // Time for launchd to start the daemon on its own.
        try? await Task.sleep(for: .seconds(2))
        let service = daemonService
        do {
            let started = try await DaemonRestart.run(
                answers: { [client] in (try? await client.status()) != nil },
                registerAgain: {
                    try await service.unregister()
                    try service.register()
                },
                sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) })
            if !started {
                serviceNote = "The daemon does not start. Quit \(Instance.current.appName) and open it again."
            }
        } catch {
            serviceNote = "Could not start the daemon again: \(error.localizedDescription)"
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refresh() async {
        do {
            let s = try await client.status()
            let j = try await client.listJobs()
            let r = try await client.listRuns(limit: 300)
            let c = try await client.config()
            status = s
            jobs = j
            let kept = DismissedFailures.prune(dismissedRuns, jobs: j)
            if kept != dismissedRuns { dismissedRuns = kept }
            runs = r
            config = c
            // An older daemon has no secrets: not an error.
            secrets = (try? await client.listSecrets()) ?? []
            // Nor messages.
            messages = (try? await client.listMessages())?.messages ?? []
            daemonProblem = nil
            now = Date()
            await refreshPlanned()
            await markMessagesSeen()
        } catch {
            status = nil
            daemonProblem = error.localizedDescription
        }
    }

    /// The next times of every job that is on, again when a schedule
    /// changed or a minute passed.
    private func refreshPlanned() async {
        let wanted = Dictionary(uniqueKeysWithValues: jobs.filter(\.job.enabled).map { ($0.id, $0.job.schedule) })
        guard wanted != plannedFor || Date().timeIntervalSince(plannedAt) > 60 else { return }
        var times: [String: [Date]] = [:]
        let horizon = Date().addingTimeInterval(8 * 86400)
        for (id, schedule) in wanted {
            guard let preview = try? await client.preview(schedule: schedule, count: 48) else { continue }
            times[id] = preview.next.compactMap(ApiDate.parse).filter { $0 < horizon }
        }
        scheduleTimes = times
        plannedFor = wanted
        plannedAt = Date()
    }

    /// Up to 5000 runs, for the calendars.
    func loadHistory() async {
        if let all = try? await client.listRuns(limit: 5000) { history = all }
    }

    /// Past runs and planned times as marks on a time line. Planned times
    /// are left out while paused: they do not run.
    func timeMarks(from runs: [Run]) -> [TimeMark] {
        let past = runs.compactMap(TimeMark.init)
        return paused ? past : past + TimeMark.planned(planned)
    }

    // MARK: Messages

    func say(_ text: String, failed: Bool = false) {
        message = text
        messageFailed = failed
    }

    func say(_ feedback: Feedback) {
        say(feedback.summary, failed: feedback.failed)
    }

    /// Runs a daemon call and reports its error in the footer.
    @discardableResult
    private func perform<T>(_ what: String, _ body: () async throws -> T) async -> T? {
        do {
            let value = try await body()
            await refresh()
            return value
        } catch {
            say("\(what): \(error.localizedDescription)", failed: true)
            return nil
        }
    }

    // MARK: Jobs and runs

    /// A job waiting for its secrets asks for the OK first: its first run
    /// would fail without it. With `early`, the run takes the place of the
    /// next scheduled run.
    func runNow(_ job: JobView, early: Bool = false) async {
        if job.secretsAllowed == false {
            guard await allowSecrets(job) else { return }
        }
        if let run = await perform("Could not run \(job.id)", { try await client.runJob(id: job.id, early: early) }) {
            let instead = run.dueAt.flatMap(ApiDate.parse).map { " It takes the place of the run \(Formatting.next($0))." } ?? ""
            say(run.status == .skipped ? "\(job.id) was not started: \(run.message)" : "\(job.id) started (\(run.id)).\(instead)",
                failed: run.status == .skipped)
        }
    }

    /// Stop: SIGTERM, then SIGKILL after 10 s. Kill: SIGKILL now.
    func cancel(_ run: Run, kill: Bool = false) async {
        let verb = kill ? "kill" : "stop"
        guard let result = await perform("Could not \(verb) \(run.id)", { try await client.cancelRun(id: run.id, force: kill) })
        else { return }
        if result.canceled {
            say(kill ? "Killed \(run.id)." : "Stopping \(run.id).")
        } else if result.run.status.isFinished {
            say("\(run.id) had already finished.")
        } else {
            say(kill ? "\(run.id) is already killed." : "\(run.id) is already stopping. Kill Now ends it at once.")
        }
    }

    func stopAll() async {
        let runs = activeRuns
        var stopped = 0
        for run in runs {
            do {
                if try await client.cancelRun(id: run.id).canceled { stopped += 1 }
            } catch {
                say("Could not stop \(run.id): \(error.localizedDescription)", failed: true)
                await refresh()
                return
            }
        }
        await refresh()
        say(stopped == 0 ? "No run to stop." : "Stopping \(stopped) run\(stopped == 1 ? "" : "s").")
    }

    func setPaused(_ paused: Bool) async {
        let what = paused ? "Could not pause" : "Could not resume"
        if await perform(what, { try await client.setConfig(SetConfigParams(paused: paused)) }) != nil {
            say(paused ? "Paused: no scheduled run starts. Run Now still works."
                       : "Resumed. Times missed while paused are not run.")
        }
    }

    func setEnabled(_ job: JobView, _ enabled: Bool) async {
        await perform("Could not change \(job.id)") { try await client.setEnabled(id: job.id, enabled: enabled) }
    }

    func delete(_ job: JobView) async {
        if await perform("Could not delete \(job.id)", { try await client.removeJob(id: job.id) }) == true {
            say("\(job.id) deleted.")
        }
    }

    /// Saves the editor's job. Returns the error to show in the editor.
    func save(_ draft: JobDraft) async -> String? {
        let job: Job
        switch draft.job() {
        case let .success(j): job = j
        case let .failure(e): return e.message
        }
        do {
            let result = try await client.setJob(job, replace: !draft.isNew)
            await refresh()
            let next = result.job.nextRun.flatMap(ApiDate.parse).map { ", next run \(Formatting.next($0))" } ?? ""
            say("\(job.id) saved: \(result.job.scheduleText)\(next).")
            page = .tabs
            tab = .jobs
            if result.job.secretsAllowed == false {
                await allowSecrets(result.job)
            }
            if !result.missingSecrets.isEmpty {
                let names = result.missingSecrets.map(\.name).joined(separator: ", ")
                say("\(job.id) saved. Not set yet: \(names). Set them in Secrets; its runs fail until then.", failed: true)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Secrets

    func newSecret() {
        page = .secretEditor(SecretDraft())
    }

    func edit(_ secret: SecretInfo) {
        page = .secretEditor(SecretDraft(secret: secret))
    }

    /// Sends the value to the daemon, which keeps it in the Keychain. Returns
    /// the error to show in the editor.
    func save(_ draft: SecretDraft) async -> String? {
        let params: SetSecretParams
        switch draft.params() {
        case let .success(p): params = p
        case let .failure(e): return e.message
        }
        do {
            let result = try await client.setSecret(params)
            await refresh()
            let what = result.created ? "stored" : params.value == nil ? "described" : "replaced"
            say("\(params.name) \(what)." + (result.secret.usedBy.isEmpty ? "" : " Used by \(result.secret.usedBy.joined(separator: ", "))."))
            page = .tabs
            tab = .secrets
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func delete(_ secret: SecretInfo) async {
        guard let result = await perform("Could not delete \(secret.name)", { try await client.removeSecret(name: secret.name) })
        else { return }
        say(result.usedBy.isEmpty ? "\(secret.name) deleted."
                                  : "\(secret.name) deleted. Runs of \(result.usedBy.joined(separator: ", ")) fail until it is set again.",
            failed: !result.usedBy.isEmpty)
    }

    /// The user reads what the job runs and what changed since the last OK,
    /// with Claude's review beside it, confirms, and proves it is them
    /// (Touch ID or the Mac password). Then the job as shown is allowed.
    /// True when it is allowed now.
    @discardableResult
    func allowSecrets(_ job: JobView) async -> Bool {
        let j = job.job
        guard await SecretApprovalWindow.ask(SecretApproval(job)) else { return false }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "allow the job \(j.id) to read its secrets")
            else { return false }
        } catch {
            say("\(j.id) was not allowed: \(error.localizedDescription)", failed: true)
            return false
        }
        guard await perform("Could not allow \(j.id)", { try await client.allowJobSecrets(j) }) != nil else { return false }
        say("\(j.id) may read its secrets now.")
        return true
    }

    func preview(_ schedule: String) async -> Result<PreviewScheduleResult, Error> {
        do {
            return .success(try await client.preview(schedule: schedule, count: 3))
        } catch {
            return .failure(error)
        }
    }

    func log(_ runID: String) async -> Result<GetRunLogResult, Error> {
        do {
            return .success(try await client.runLog(id: runID))
        } catch {
            return .failure(error)
        }
    }

    func newJob() {
        page = .editor(JobDraft())
    }

    func edit(_ job: JobView) {
        page = .editor(JobDraft(job: job.job))
    }

    /// The Runs tab, filtered to one job.
    func showRuns(jobID: String) {
        page = .tabs
        tab = .runs
        runsMode = .list
        runFilter = .all
        runJobFilter = jobID
    }

    /// The tokens of one job, or of all with nil.
    func showUsage(jobID: String?) {
        page = .tabs
        tab = .runs
        runsMode = .usage
        usageJob = jobID
    }

    /// The history, with the newest runs from the last poll.
    var allRuns: [Run] {
        let fresh = Set(runs.map(\.id))
        return runs + history.filter { !fresh.contains($0.id) }
    }

    func job(_ id: String) -> JobView? { jobs.first { $0.id == id } }

    // MARK: Messages from runs

    /// While the user looks at the Messages tab, its unread messages become
    /// read; they stay marked as new until the popover closes.
    func markMessagesSeen() async {
        guard windowOpen, page == .tabs, tab == .messages else { return }
        let unread = messages.filter { !$0.read }.map(\.id)
        guard !unread.isEmpty else { return }
        newMessageIDs.formUnion(unread)
        guard let result = try? await client.readMessages(ids: unread) else { return }
        for i in messages.indices where unread.contains(messages[i].id) { messages[i].read = true }
        status?.unreadMessages = result.unread
    }

    func removeMessage(_ message: Message) async {
        await perform("Could not remove the message") { try await client.removeMessages(ids: [message.id]) }
    }

    func clearMessages() async {
        if let result = await perform("Could not remove the messages", { try await client.removeMessages() }) {
            say(result.changed == 1 ? "Removed 1 message." : "Removed \(result.changed) messages.")
        }
    }

    /// The run a message came from, when the daemon still keeps it.
    func run(_ id: String) -> Run? { runs.first { $0.id == id } }

    func showLog(_ run: Run) {
        showLog(runID: run.id)
    }

    /// The Runs window at the calendar.
    func showCalendar() {
        runsWindowTab = .calendar
        openWeek()
    }

    /// The Runs window at the Logs tab, with the run chosen last.
    func showLogs() {
        runsWindowTab = .logs
        openWeek()
    }

    /// The Runs window at the Logs tab, with this run's log.
    func showLog(runID: String) {
        logRunID = runID
        runsWindowTab = .logs
        openWeek()
    }

    func revealLog(_ run: Run) {
        guard let path = run.log else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            say("The log file of \(run.id) is gone.", failed: true)
        }
    }

    var kittyURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: ConsoleTerminal.kittyBundleID) }

    /// Settings saves the choice (@AppStorage); read at each open.
    var consoleTerminal: ConsoleTerminal {
        ConsoleTerminal.chosen(saved: UserDefaults.standard.string(forKey: ConsoleTerminal.defaultsKey), kittyInstalled: kittyURL != nil)
    }

    /// The run's interactive console, in kitty or Terminal.
    func openTerminal(_ run: Run) {
        guard let command = run.console else {
            say("\(run.id) has no console: it runs without one, or it has ended. Claude jobs get one when tmux is installed.",
                failed: true)
            return
        }
        open(command, runID: run.id, title: "\(run.id) console", dir: nil, note: nil, suffix: "",
             done: "The console of \(run.id) opens in %@. Leave it with Ctrl-B, then D: the run goes on.")
    }

    /// Open a finished Claude run's session again, in the job's folder:
    /// `claude --resume <session>` in a new terminal window.
    func resume(_ run: Run) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let session = run.sessionId, let job = job(run.jobId),
              let command = ConsoleScript.resumeCommand(session: session, shell: shell) else {
            say("\(run.id) has no Claude session to resume.", failed: true)
            return
        }
        open(command, runID: run.id, title: "\(run.id) resume", dir: job.job.dir, note: "Resume the session of \(run.id).",
             suffix: "-resume", done: "The session of \(run.id) opens in %@.")
    }

    /// Run `command` in a new window of the chosen terminal; `done` has %@ for its name.
    private func open(_ command: String, runID: String, title: String, dir: String?, note: String?, suffix: String,
                      done: String) {
        if consoleTerminal == .kitty, let kitty = kittyURL {
            let process = Process()
            process.executableURL = kitty.appendingPathComponent("Contents/MacOS/kitty")
            process.arguments = ConsoleTerminal.kittyArguments(command: command, runID: runID, title: title, dir: dir)
            do {
                try process.run()
                say(done.replacingOccurrences(of: "%@", with: "kitty"))
            } catch {
                say("Could not open kitty: \(error.localizedDescription)", failed: true)
            }
            return
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(Instance.current.appName)-consoles")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(try ConsoleScript.write(runID: runID, command: command, in: folder, workDir: dir,
                                                            note: note, suffix: suffix))
            say(done.replacingOccurrences(of: "%@", with: "Terminal"))
        } catch {
            say("Could not open Terminal for \(runID): \(error.localizedDescription)", failed: true)
        }
    }

    func openLogInConsole(_ run: Run) {
        guard let path = run.log else { return }
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The help page of this bundle, in the default web browser: the app for
    /// .html files may be an editor.
    func openHelp() {
        let page = Bundle.main.bundleURL.appendingPathComponent(BundleLayout.helpPage)
        guard FileManager.default.fileExists(atPath: page.path) else {
            say("The help page is missing: \(page.path). It is made by scripts/build-app.sh.", failed: true)
            return
        }
        NSApp.activate()
        if let https = URL(string: "https://example.com"), let browser = NSWorkspace.shared.urlForApplication(toOpen: https) {
            NSWorkspace.shared.open([page], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(page)
        }
    }

    func openLogsFolder() {
        let dir = status.map { URL(fileURLWithPath: $0.logsDir) } ?? Paths.logsDir
        let runsDir = dir.appendingPathComponent("runs")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: runsDir.path) ? runsDir : dir)
    }

    func setConfig(maxConcurrent: UInt32? = nil, logBudgetMB: UInt32? = nil) async {
        await perform("Could not save the settings") {
            try await client.setConfig(SetConfigParams(maxConcurrent: maxConcurrent, logBudgetMB: logBudgetMB))
        }
    }

    // MARK: Coding agents

    @discardableResult
    func installCLI() -> Feedback {
        let feedback: Feedback
        do {
            let installer = CLIInstaller()
            switch try installer.install() {
            case let .installed(link, onPath):
                feedback = .cliInstalled(link: link, onPath: onPath, pathHint: installer.pathHint)
            }
        } catch {
            feedback = .failed("Could not install the command line tool", error.localizedDescription)
        }
        say(feedback)
        agentResult = (.installCLI, feedback, Date())
        return feedback
    }

    /// The program the MCP server entries start. Installs the CLI link first
    /// when it is missing, so the entry does not name a path inside the app.
    private func mcpCommandPath() -> String {
        let cli = CLIInstaller()
        if !cliInstalled { _ = try? cli.install() }
        return cli.commandPath
    }

    var cliInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: CLIInstaller().link.path)) != nil
    }

    var mcpCommand: String {
        commandLine(ClaudeInstaller().addCommand(commandPath: cliInstalled ? CLIInstaller().link.path : CLIInstaller().commandPath))
    }

    /// Links the note, imports it in CLAUDE.md and runs `claude mcp add`.
    /// The shell can take seconds, so it runs off the main thread.
    @discardableResult
    func installClaude() async -> Feedback {
        busy = true
        say("Adding \(Instance.current.appName) to Claude Code…")
        let path = mcpCommandPath()
        let feedback = await Task.detached { () -> Feedback in
            do {
                let installer = ClaudeInstaller()
                switch try installer.install(commandPath: path) {
                case let .installed(link, importAdded, mcp):
                    return .claudeInstalled(link: link, claudeMD: installer.claudeMD, importAdded: importAdded, mcp: mcp)
                case let .noClaude(dir):
                    return .noClaude(dir)
                }
            } catch {
                return .failed("Could not add \(Instance.current.appName) to Claude Code", error.localizedDescription)
            }
        }.value
        busy = false
        say(feedback)
        agentResult = (.installClaude, feedback, Date())
        return feedback
    }

    @discardableResult
    func installCodex() -> Feedback {
        let feedback: Feedback
        do {
            switch try CodexInstaller().install(commandPath: mcpCommandPath()) {
            case let .installed(link, agentsMD, instructionAdded, configTOML, serverAdded):
                feedback = .codexInstalled(link: link, agentsMD: agentsMD, instructionAdded: instructionAdded,
                                           configTOML: configTOML, serverAdded: serverAdded)
            case let .noCodex(dir):
                feedback = .noCodex(dir)
            }
        } catch {
            feedback = .failed("Could not add \(Instance.current.appName) to Codex", error.localizedDescription)
        }
        say(feedback)
        agentResult = (.installCodex, feedback, Date())
        return feedback
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        say("Copied: \(text)")
    }

    var menuContext: AppMenu.Context {
        let now = Date()
        let summary = status.map { "\($0.enabledJobs) of \($0.jobs) on" + ($0.paused ? ", paused" : "") }
        let failed = status == nil ? [] : jobs.compactMap { job -> AppMenu.RunEntry? in
            guard let last = job.lastRun, last.failed, !dismissedRuns.contains(last.id) else { return nil }
            var parts: [String] = []
            if let at = last.shownAt { parts.append(Formatting.when(at, now: now)) }
            parts.append(!last.status.isFailure ? "reported an error" : last.exitCode.map { "exit \($0)" } ?? last.status.title.lowercased())
            return AppMenu.RunEntry(runID: last.id, jobID: job.id, detail: parts.joined(separator: ", "))
        }
        let waiting = status == nil ? [] : jobs.filter { $0.secretsAllowed == false }.map {
            AppMenu.WaitingJob(jobID: $0.id, secrets: Array(Set($0.job.secretEnv.values)).sorted())
        }
        return AppMenu.Context(appName: Instance.current.appName, cliInstalled: cliInstalled, summary: summary,
                               paused: paused, failed: failed, waiting: waiting,
                               jobIDs: status == nil ? [] : jobs.map(\.id))
    }

    // MARK: Updates

    func checkForUpdates(manual: Bool) async {
        if case .downloading = update { return }
        if let reason = Updater.disabledReason(for: .current) {
            update = manual ? .failed(reason) : .idle
            return
        }
        update = .checking
        do {
            let release = try await Updater.latest(currentVersion: version)
            if Updater.isNewer(release.version, than: version) {
                update = .available(release)
            } else {
                update = manual ? .upToDate : .idle
            }
        } catch {
            update = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    func installUpdate(_ release: Updater.Release) async {
        if let obstacle = Updater.disabledReason(for: .current) ?? Updater.obstacle(appURL: Bundle.main.bundleURL) {
            update = .failed(obstacle)
            return
        }
        update = .downloading(release)
        do {
            let dmg = try await Updater.download(release)
            try await Task.detached { try Updater.checkImage(dmg) }.value
            try Updater.startInstall(dmg: dmg, app: Bundle.main.bundleURL)
            try? await Task.sleep(for: .milliseconds(600))
            NSApp.terminate(nil)
        } catch {
            update = .failed(error.localizedDescription)
        }
    }

    // MARK: Uninstall

    /// Stop the daemon, delete data, logs and links. The user then moves the
    /// app to the Trash.
    func uninstall() async {
        busy = true
        try? await daemonService.unregister()
        await Task.detached { Uninstaller().removeFiles() }.value
        busy = false
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        say("\(Instance.current.appName) is uninstalled. Move \(Instance.current.appName).app to the Trash.")
        try? await Task.sleep(for: .seconds(4))
        NSApp.terminate(nil)
    }
}
