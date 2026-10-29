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

    enum Tab: Hashable {
        case jobs, runs, secrets, settings
    }

    /// What the window shows in place of the tabs.
    enum Page: Equatable {
        case tabs
        case editor(JobDraft)
        case secretEditor(SecretDraft)
        case log(runID: String)
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
    var tab: Tab = .jobs
    var page: Page = .tabs
    /// The popover is open: poll often.
    var windowOpen = false {
        didSet { if windowOpen && !oldValue { pollNow() } }
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
    var statusIcon: StatusIcon { StatusIcon(status: status, jobs: jobs) }

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

    /// An ad-hoc build gets a new signature each time it is built. After
    /// scripts/install.sh replaces the app, launchd keeps the old launch
    /// constraint and refuses to start the new daemon. Registering again
    /// records the new signature. Release builds are signed by team and are
    /// not affected.
    private func registerAgainIfStale() async {
        guard inBundle, BuildKind.current == .dev, daemonService.status == .enabled else { return }
        try? await Task.sleep(for: .seconds(2))
        guard (try? await client.status()) == nil else { return }
        do {
            try await daemonService.unregister()
            try daemonService.register()
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
            let r = try await client.listRuns(limit: 100)
            let c = try await client.config()
            status = s
            jobs = j
            runs = r
            config = c
            // An older daemon has no secrets: not an error.
            secrets = (try? await client.listSecrets()) ?? []
            daemonProblem = nil
        } catch {
            status = nil
            daemonProblem = error.localizedDescription
        }
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
    /// would fail without it.
    func runNow(_ job: JobView) async {
        if job.secretsAllowed == false {
            guard await allowSecrets(job) else { return }
        }
        if let run = await perform("Could not run \(job.id)", { try await client.runJob(id: job.id) }) {
            say(run.status == .skipped ? "\(job.id) was not started: \(run.message)" : "\(job.id) started (\(run.id)).",
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

    /// The user reads what the job runs, confirms, and proves it is them
    /// (Touch ID or the Mac password). Then the job as shown is allowed.
    /// True when it is allowed now.
    @discardableResult
    func allowSecrets(_ job: JobView) async -> Bool {
        let j = job.job
        let what = j.kind == .shell ? "Command: \(j.command ?? "")" : "\(j.kind.title) prompt: \(j.prompt ?? "")"
        let secrets = j.secretEnv.sorted { $0.key < $1.key }.map { "\($0.key) from \($0.value)" }.joined(separator: ", ")
        let detail = """
        \(what)
        Folder: \((j.dir as NSString).abbreviatingWithTildeInPath)
        Secrets: \(secrets)

        The job can do anything with these values, also send them elsewhere. \
        Allow it only if you wrote it or read it. A change to what it runs needs a new OK.
        """
        guard confirm("Allow \(j.id) to read its secrets?", detail, button: "Allow…", destructive: false) else { return false }
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

    func showLog(_ run: Run) {
        showLog(runID: run.id)
    }

    func showLog(runID: String) {
        page = .log(runID: runID)
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

    func setConfig(maxConcurrent: UInt32? = nil, keepRuns: UInt32? = nil) async {
        await perform("Could not save the settings") {
            try await client.setConfig(SetConfigParams(maxConcurrent: maxConcurrent, keepRuns: keepRuns))
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
        var summary: String?
        if let status {
            summary = "\(status.jobs) job\(status.jobs == 1 ? "" : "s")"
            if status.running > 0 { summary! += ", \(status.running) running" }
            if let next = status.next, let at = ApiDate.parse(next.at) {
                summary! += ", next: \(next.jobId) \(Formatting.next(at))"
            }
        }
        let running = activeRuns.map { run in
            let detail = run.status == .queued ? "queued" : run.seconds.map { "running for \(Formatting.duration($0))" }
            return AppMenu.RunEntry(runID: run.id, jobID: run.jobId, detail: detail)
        }
        let failed = status == nil ? [] : jobs.compactMap { job -> AppMenu.RunEntry? in
            guard let last = job.lastRun, last.status.isFailure else { return nil }
            var parts = [last.status.title]
            if let code = last.exitCode { parts.append("exit \(code)") }
            if let ended = ApiDate.parse(last.endedAt) { parts.append(Formatting.past(ended)) }
            return AppMenu.RunEntry(runID: last.id, jobID: job.id, detail: parts.joined(separator: " · "))
        }
        let waiting = status == nil ? [] : jobs.filter { $0.secretsAllowed == false }.map {
            AppMenu.WaitingJob(jobID: $0.id, secrets: Array(Set($0.job.secretEnv.values)).sorted())
        }
        return AppMenu.Context(appName: Instance.current.appName, cliInstalled: cliInstalled, summary: summary,
                               paused: paused, running: running, failed: failed, waiting: waiting)
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
