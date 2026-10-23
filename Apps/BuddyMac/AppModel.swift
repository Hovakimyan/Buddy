import BuddyKit
import Foundation
import Observation

/// The app's view model: mirrors the engine's snapshots for the UI, forwards decisions, and owns the
/// "install hooks" flow (copy the embedded `buddy-hook`, then patch `~/.claude/settings.json`).
@MainActor
@Observable
final class AppModel {
    /// Where the install flow reads and writes. Injectable so tests use temp directories.
    struct Paths: Sendable {
        /// Claude Code's settings file (`~/.claude/settings.json`).
        var settingsURL: URL
        /// Buddy's support directory (`~/Library/Application Support/Buddy`); the hook goes to `bin/buddy-hook`.
        var supportDirectory: URL
        /// The `buddy-hook` executable to install (the copy embedded in the app bundle), if there is one.
        var hookBinarySource: URL?
        /// Set when the environment overrides are unusable (see `standard`). Everything that would read or write
        /// the settings file or the support directory then refuses, so nothing is ever done at a location the
        /// person did not choose.
        var configurationError: String?

        /// The real locations, with the same test overrides `buddyctl` has: `BUDDY_SETTINGS` (settings.json
        /// path) and `BUDDY_HOME` (support directory). Both or neither, like `buddyctl`: with only one, the other
        /// would fall back to the real location and a test path could end up in the real settings file, so that
        /// is a `configurationError` (and an override counts as set only when non-empty).
        static func standard(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            bundle: Bundle = .main
        ) -> Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let settingsSet = !(environment["BUDDY_SETTINGS"] ?? "").isEmpty
            let homeSet = !(environment["BUDDY_HOME"] ?? "").isEmpty
            var configurationError: String?
            if settingsSet != homeSet {
                let only = settingsSet ? "BUDDY_SETTINGS" : "BUDDY_HOME"
                let missing = settingsSet ? "BUDDY_HOME" : "BUDDY_SETTINGS"
                configurationError = "\(only) is set but \(missing) is not. Set both (a test setup) or neither; hook install and uninstall are disabled until then."
            }
            let settings = environment["BUDDY_SETTINGS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude/settings.json")
            let support = environment["BUDDY_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent("Library/Application Support/Buddy", isDirectory: true)
            return Paths(
                settingsURL: settings,
                supportDirectory: support,
                hookBinarySource: bundle.url(forAuxiliaryExecutable: HookBinaryInstaller.executableName),
                configurationError: configurationError)
        }
    }

    enum ActionError: Error, Equatable {
        /// The settings file no longer matches the plan the user reviewed.
        case settingsChangedSinceReview
        /// The app bundle has no embedded `buddy-hook` to install.
        case hookBinaryUnavailable
        case unreadableSettings(String)
        /// The hook binary was copied, but writing the settings file then failed (settings untouched).
        case settingsWriteFailedAfterBinaryInstall(binary: String, reason: String)
        /// BUDDY_SETTINGS and BUDDY_HOME were not set together (`Paths.configurationError`).
        case invalidConfiguration(String)
    }

    private(set) var sessions: [Session] = []
    private(set) var pending: [PendingApproval] = []
    private(set) var questions: [PendingQuestion] = []
    /// How recent questions ended, oldest first (the engine's bounded list).
    private(set) var questionOutcomes: [QuestionOutcomeRecord] = []
    /// True when the settings file currently contains Buddy hook entries.
    private(set) var hooksInstalled = false
    /// How those entries compare with what this version installs (read with `hooksInstalled`).
    private(set) var hookStatus = HookInstallStatus.notInstalled
    private(set) var engineRunning = false
    /// True once a `start()` has finished (succeeded or failed). Until then "not running" only means
    /// "not started yet", so the UI must not report it as a problem.
    private(set) var hasAttemptedStart = false
    /// Why the engine is not listening (set only by a failed `start()`, cleared only by a successful one).
    /// Unrelated actions never touch it.
    private(set) var engineError: String?
    /// What to show when the engine is not listening, nil while it is running or has not yet had its
    /// first start attempt (so the menu does not flash "Not listening" while launching).
    var notListeningNotice: String? {
        guard hasAttemptedStart, !engineRunning else { return nil }
        return engineError.map { "Not listening: \($0)" } ?? "Not listening"
    }

    /// The last install/uninstall problem worth showing. Nil when there is none. Engine problems use `engineError`.
    var errorMessage: String?
    /// What the last successful install/uninstall did, including the backup path.
    private(set) var resultMessage: String?
    /// What the launch-time refresh of the installed `buddy-hook` did (nil until it has run).
    private(set) var hookRefresh: HookCopyRefresh.Outcome?
    /// Whether Buddy runs from Applications, or from a place it is never moved from (a development build): the first
    /// setup step. Set by `LaunchCoordinator` at launch.
    var inApplications = true
    /// The project of the first hook event Buddy ever saw (remembered across launches), nil until one arrives.
    private(set) var seenEventProject: String?
    /// The "Launch at login" setting.
    let launchAtLogin: LaunchAtLogin
    /// The demo playing on the island, if one is (`startDemo`).
    private var demo: DemoFeed?

    /// The `UserDefaults` key of "Answer Claude's questions in Buddy".
    static let questionsEnabledKey = "questions.enabled"

    /// "Answer Claude's questions in Buddy" (default on). Off, the `--ask` hook always returns at once and Claude Code
    /// asks in the terminal.
    var questionsEnabled: Bool {
        didSet { defaults.set(questionsEnabled, forKey: Self.questionsEnabledKey) }
    }

    /// Whether the phone link is running, and if not why not. Never an error: without it the Mac card
    /// works exactly the same.
    private(set) var phoneLinkStatus: PhoneLinkStatus

    /// How to build the engine once the phone link has been decided (see `init(selector:makeEngine:paths:)`).
    private struct DeferredEngine {
        let selector: PhoneLinkSelector
        let makeEngine: MakeEngine
    }

    /// Builds the engine from the phone link's transport (if any) and the gate it asks before a question waits
    /// (`canAskInBuddy`).
    typealias MakeEngine = @Sendable (CloudKitTransport?, _ canAskInBuddy: @escaping @Sendable () async -> Bool)
        -> BuddyEngine

    @ObservationIgnored private var engine: BuddyEngine?
    @ObservationIgnored private let deferredEngine: DeferredEngine?
    @ObservationIgnored private var cloudTransport: CloudKitTransport?
    @ObservationIgnored private let paths: Paths
    @ObservationIgnored private let setupMemory: any SetupMemory
    /// After installing hooks that were outdated or missing, only sessions active since then count for "Check it works".
    @ObservationIgnored private var setupEventsSince: Date?
    /// Whether this build has CloudKit, so the setup window lists the iPhone step. Read once, when first needed (the
    /// engine's own phone-link check is separate). Never with an engine built by a test.
    @ObservationIgnored private(set) lazy var cloudEnabled: Bool = deferredEngine?.selector.hasEntitlement() ?? false
    @ObservationIgnored private let defaults: UserDefaults
    /// Whether the screen is locked or asleep, for `canAskInBuddy`.
    @ObservationIgnored private let screen: ScreenPresence
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    /// Checks iCloud again after a retryable "off" (see `PhoneLink.retryable`).
    @ObservationIgnored private var phoneLinkRetryTask: Task<Void, Never>?
    /// Called when a later iCloud check turned the phone link on (the app registers for pushes then).
    @ObservationIgnored var onPhoneLinkOn: (@MainActor () -> Void)?
    /// The last check said "off, but it may come on by itself".
    @ObservationIgnored private var linkRetryable = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var stopRequested = false

    /// An engine that is already built (no phone link, so no CloudKit). Used by tests. Both initializers default the
    /// login item and the setup memory to ones that touch nothing real; only the app passes the real ones (see
    /// `LaunchEnvironment`).
    init(
        engine: BuddyEngine, paths: Paths = .standard(), loginItem: any LoginItemService = NoLoginItem(),
        setupMemory: any SetupMemory = VolatileSetupMemory(), defaults: UserDefaults = .standard,
        screen: ScreenPresence = ScreenPresence()
    ) {
        self.engine = engine
        self.launchAtLogin = LaunchAtLogin(service: loginItem)
        self.setupMemory = setupMemory
        self.seenEventProject = setupMemory.seenEventProject
        self.defaults = defaults
        self.screen = screen
        self.questionsEnabled = defaults.object(forKey: Self.questionsEnabledKey) as? Bool ?? true
        self.deferredEngine = nil
        self.phoneLinkStatus = .off(reason: "not configured")
        self.paths = paths
        self.errorMessage = paths.configurationError
        refreshHooksInstalled()
    }

    /// The app's init: the engine is built in `start()`, after `selector` has decided (asynchronously,
    /// from the iCloud account state) whether there is a CloudKit transport to give it. The engine is handed
    /// `canAskInBuddy` as its gate for questions.
    init(
        selector: PhoneLinkSelector, makeEngine: @escaping MakeEngine,
        paths: Paths = .standard(), loginItem: any LoginItemService = NoLoginItem(),
        setupMemory: any SetupMemory = VolatileSetupMemory(), defaults: UserDefaults = .standard,
        screen: ScreenPresence = ScreenPresence()
    ) {
        self.engine = nil
        self.launchAtLogin = LaunchAtLogin(service: loginItem)
        self.setupMemory = setupMemory
        self.seenEventProject = setupMemory.seenEventProject
        self.defaults = defaults
        self.screen = screen
        self.questionsEnabled = defaults.object(forKey: Self.questionsEnabledKey) as? Bool ?? true
        self.deferredEngine = DeferredEngine(selector: selector, makeEngine: makeEngine)
        self.phoneLinkStatus = .checking
        self.paths = paths
        self.errorMessage = paths.configurationError
        refreshHooksInstalled()
    }

    isolated deinit {
        snapshotTask?.cancel()
        phoneLinkRetryTask?.cancel()
    }

    // MARK: Engine

    /// Subscribes to the engine's snapshots, then starts it. A start failure (for example an unusable
    /// socket path) is published in `engineError`; the app keeps running without live sessions.
    func start() async {
        guard !engineRunning, !isStarting else { return }
        isStarting = true
        stopRequested = false
        defer { isStarting = false }
        refreshHooksInstalled()
        if engine == nil, let deferredEngine {
            let link = await deferredEngine.selector.select()
            guard !stopRequested else { return }
            cloudTransport = link.transport
            phoneLinkStatus = link.status
            engine = deferredEngine.makeEngine(link.transport, askGate)
            linkRetryable = link.retryable
        }
        if linkRetryable, cloudTransport == nil, phoneLinkRetryTask == nil, let deferredEngine {
            schedulePhoneLinkRetry(deferredEngine)
        }
        await startEngine()
    }

    private func startEngine() async {
        guard let engine else { return }
        if snapshotTask == nil {
            let stream = await engine.snapshots()
            snapshotTask = Task { [weak self] in
                for await snapshot in stream {
                    guard let self else { return }
                    self.apply(snapshot)
                }
            }
        }
        do {
            try await engine.start()
            engineRunning = true
            engineError = nil
        } catch {
            engineRunning = false
            engineError = Self.describe(error)
        }
        hasAttemptedStart = true
    }

    /// Checks iCloud again on the selector's delays until the link is on, cannot come on, or Buddy stops. When
    /// it comes on, the running engine (which has no transport) is replaced by one that has, at a moment when no
    /// request (approval, plan or question) is waiting: the new engine starts with an empty session list, refilled by
    /// the next hook events, and a hook that connects during the swap just falls back to the terminal.
    private func schedulePhoneLinkRetry(_ deferred: DeferredEngine) {
        phoneLinkRetryTask?.cancel()
        phoneLinkRetryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: deferred.selector.retryDelay(attempt: attempt)) } catch { return }
                attempt += 1
                guard let self else { return }
                guard !self.stopRequested, self.engineRunning, self.noRequestWaits else { continue }
                let link = await deferred.selector.select()
                guard !Task.isCancelled, !self.stopRequested else { return }
                guard let transport = link.transport else {
                    self.phoneLinkStatus = link.status
                    self.linkRetryable = link.retryable
                    if link.retryable { continue } else { return }
                }
                guard self.engineRunning, self.noRequestWaits else {
                    transport.stop()  // a request arrived during the check: try again later
                    continue
                }
                await self.swapEngine(
                    deferred.makeEngine(transport, self.askGate), transport: transport, status: link.status)
                return
            }
        }
    }

    /// No approval, plan or question waits: stopping the engine now loses nothing anybody is answering.
    private var noRequestWaits: Bool { pending.isEmpty && questions.isEmpty }

    private func swapEngine(_ newEngine: BuddyEngine, transport: CloudKitTransport, status: PhoneLinkStatus) async {
        snapshotTask?.cancel()
        snapshotTask = nil
        await engine?.stop()
        engineRunning = false
        guard !stopRequested else {
            transport.stop()
            return
        }
        engine = newEngine
        cloudTransport = transport
        phoneLinkStatus = status
        linkRetryable = false
        await startEngine()
        onPhoneLinkOn?()
    }

    /// Stops the engine (removing its socket file) and ends the snapshot subscription.
    func stop() async {
        stopRequested = true
        phoneLinkRetryTask?.cancel()
        phoneLinkRetryTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        await engine?.stop()
        cloudTransport?.stop()  // no more polling or open streams after quit
        engineRunning = false
    }

    /// Forwards a Mac decision. False when the request is unknown, already resolved or expired, and for an allow
    /// of a request whose command was cut short (`summary.isTruncated`): nobody could have read all of it, so
    /// it is answered in the terminal, like the phone bridge does. Deny always goes through.
    @discardableResult
    func decide(_ id: UUID, _ decision: Decision) async -> Bool {
        if decision == .allow {
            guard let request = pending.first(where: { $0.id == id }), !request.summary.isTruncated else { return false }
        }
        guard let engine else { return false }
        return await engine.decide(requestId: id, decision)
    }

    /// Whether a question may wait for an answer in Buddy right now (`Presence.canAskInBuddy`): the setting, the
    /// screen, and whether the phone link is live. The engine asks this when a question arrives.
    func canAskInBuddy() -> Bool {
        Presence.canAskInBuddy(
            enabled: questionsEnabled, screenLocked: screen.locked, screenAsleep: screen.asleep,
            phoneLinkLive: phoneLinkStatus == .on)
    }

    /// `canAskInBuddy` for the engine: it hops to the main actor; with the model gone nobody can answer.
    private var askGate: @Sendable () async -> Bool {
        { [weak self] in await self?.canAskInBuddy() ?? false }
    }

    /// True when this run has a CloudKit transport, so the app should register for its silent pushes.
    var wantsRemoteNotifications: Bool { cloudTransport != nil }

    /// Forwards a remote notification to the phone link. False when there is none or the push is not Buddy's.
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        cloudTransport?.handleRemoteNotification(userInfo: userInfo) ?? false
    }

    private func apply(_ snapshot: EngineSnapshot) {
        sessions = snapshot.sessions
        pending = snapshot.pending
        questions = snapshot.questions
        questionOutcomes = snapshot.recentQuestionOutcomes
        // Sessions only come from hook events (the demo never passes here): the first one that names its project
        // completes "Check it works" (after a hook install or update, only one active since then).
        if seenEventProject == nil {
            let named = sessions.filter { session in
                session.project != Session.unknownProject && setupEventsSince.map { session.updatedAt > $0 } ?? true
            }
            if let first = named.max(by: { $0.updatedAt < $1.updatedAt }) {
                seenEventProject = first.project
                setupMemory.seenEventProject = first.project
            }
        }
        // A real request must never wait behind the demo: it ends at once and the island shows the request.
        if isDemoRunning, !pending.isEmpty || !questions.isEmpty { stopDemo() }
    }

    // MARK: Demo

    /// What the island shows: the demo while one runs, the engine's snapshots otherwise.
    var islandFeed: any IslandFeed { demo ?? self }

    var isDemoRunning: Bool { demo != nil }

    /// A demo can start only while no real request waits (one arriving later ends it).
    var canStartDemo: Bool { noRequestWaits }

    /// Plays the scripted demo on the island (menu "Demo", the setup window's "Try the demo"). Nothing of it reaches the
    /// engine, the phone or the disk, and the model's own state stays the engine's. Does nothing while a demo runs
    /// or a real request waits. `feed` is the demo to play; tests pass one with their own clock.
    func startDemo(_ feed: DemoFeed = DemoFeed()) {
        guard !isDemoRunning, canStartDemo else { return }
        feed.onEnd = { [weak self, weak feed] in
            guard let self, let feed, self.demo === feed else { return }
            self.demo = nil
        }
        demo = feed
        feed.start()
    }

    /// Ends the demo ("Stop demo"); the island shows the engine's snapshots again.
    func stopDemo() {
        demo?.stop()
        demo = nil
    }

    // MARK: Hook installation

    /// Computes the install diff. Never writes anything.
    func planInstall() throws -> InstallPlan {
        try ClaudeSettingsInstaller.planInstall(existing: readSettings(), hookCommand: hookCommand)
    }

    /// Computes the uninstall diff. Never writes anything.
    func planUninstall() throws -> InstallPlan {
        try ClaudeSettingsInstaller.planUninstall(existing: readSettings())
    }

    /// Copies the embedded `buddy-hook` into the support directory, then writes the plan to the settings
    /// file (backing it up first). The plan is re-derived from the file as it is now; if the file changed
    /// or became malformed since the user reviewed it, this throws and writes nothing. Settings are only
    /// touched after the binary is in place, so they never point at a missing hook.
    /// Updating outdated hooks, or installing them after an uninstall, starts "Open sessions pick it up" and "Check it
    /// works" over: an event from before proves nothing about the hooks installed now.
    func applyInstall(_ plan: InstallPlan) throws {
        try requireCurrent(plan, against: planInstall())
        let checkAgain = ClaudeSettingsInstaller.status(existing: try? readSettings()) != .current
        guard let source = paths.hookBinarySource else { throw ActionError.hookBinaryUnavailable }
        let installed = try HookBinaryInstaller.install(source: source, into: paths.supportDirectory)
        let backup: URL?
        do {
            backup = try write(plan)
        } catch {
            throw ActionError.settingsWriteFailedAfterBinaryInstall(
                binary: installed.path, reason: Self.describe(error))
        }
        resultMessage = Self.summary("Installed \(installed.path).", changed: plan.changed, backup: backup, settings: paths.settingsURL)
        errorMessage = nil
        if checkAgain {
            seenEventProject = nil
            setupMemory.seenEventProject = nil
            setupEventsSince = Date()
        }
        refreshHooksInstalled()
    }

    /// Removes Buddy's hook entries from the settings file (backing it up first). Same re-check as
    /// `applyInstall`. The copied binary is left in place (harmless without settings entries).
    func applyUninstall(_ plan: InstallPlan) throws {
        try requireCurrent(plan, against: planUninstall())
        let backup = try write(plan)
        resultMessage = Self.summary("Removed Buddy hooks.", changed: plan.changed, backup: backup, settings: paths.settingsURL)
        errorMessage = nil
        refreshHooksInstalled()
    }

    /// At launch: when Buddy's hooks are installed and run the copy in the support directory, and that copy differs
    /// from the `buddy-hook` in this app, replaces it (staged, atomic). Never edits the settings file, does nothing
    /// when the hooks are not installed, and leaves the copy alone while another Buddy runs (`otherInstanceRunning`).
    /// Refuses under an unusable `BUDDY_*` configuration, like every other file action.
    func refreshInstalledHookCopy(otherInstanceRunning: Bool = false) {
        refreshHooksInstalled()
        guard paths.configurationError == nil else { return }
        let usesSupportCopy = hooksInstalled
            && HookCopyRefresh.pointsAtSupportCopy(settings: try? readSettings(), supportDirectory: paths.supportDirectory)
        hookRefresh = HookCopyRefresh.run(
            hooksInstalled: hooksInstalled, entriesUseSupportCopy: usesSupportCopy,
            otherInstanceRunning: otherInstanceRunning, source: paths.hookBinarySource,
            supportDirectory: paths.supportDirectory)
    }

    // MARK: Setup steps

    /// The setup window's steps, from the current state.
    var setupSteps: [SetupStep] {
        SetupSteps.make(
            inApplications: inApplications, hookStatus: hookStatus, sawEventProject: seenEventProject,
            cloudEnabled: cloudEnabled, openAtLogin: launchAtLogin.isOn)
    }

    /// True while a required setup step is not done (the dot on the menu item).
    var setupNeedsAttention: Bool { SetupSteps.needsAttention(setupSteps) }

    /// At launch: true on a first launch (the window has never been shown) and whenever the hooks are outdated. It only
    /// decides; nothing is installed, and the "shown" mark is set later, by `setupWindowDidAppear`, once the window is
    /// really on screen.
    func shouldOpenSetupAtLaunch() -> Bool {
        refreshHooksInstalled()
        return !setupMemory.windowShown || hookStatus == .outdated
    }

    /// The setup window is on screen: it need not open by itself on the next launch (unless the hooks are outdated).
    func setupWindowDidAppear() {
        setupMemory.windowShown = true
    }

    /// The setup window is moving the app to Applications: the copy that opens next must show the window again, so
    /// setup carries on where it was.
    func setupWillRelaunch() {
        setupMemory.windowShown = false
    }

    /// Re-reads the settings file and updates `hooksInstalled` and `hookStatus`. A missing or malformed file counts as
    /// not installed.
    func refreshHooksInstalled() {
        let data = try? readSettings()
        hooksInstalled = (try? ClaudeSettingsInstaller.planUninstall(existing: data))?.changed ?? false
        hookStatus = ClaudeSettingsInstaller.status(existing: data)
    }

    /// Shows an error from an install/uninstall action.
    func report(_ error: Error) {
        errorMessage = Self.describe(error)
        resultMessage = nil
    }

    private var hookCommand: String {
        ClaudeSettingsInstaller.shellQuote(HookBinaryInstaller.destination(in: paths.supportDirectory).path)
    }

    private func readSettings() throws -> Data? {
        // Every install, uninstall and status read starts here, so this one check covers them all.
        if let problem = paths.configurationError { throw ActionError.invalidConfiguration(problem) }
        guard FileManager.default.fileExists(atPath: paths.settingsURL.path) else { return nil }
        do {
            return try Data(contentsOf: paths.settingsURL)
        } catch {
            throw ActionError.unreadableSettings("\(paths.settingsURL.path): \(error.localizedDescription)")
        }
    }

    private func requireCurrent(_ plan: InstallPlan, against current: InstallPlan) throws {
        guard current.changed == plan.changed, current.newData == plan.newData else {
            throw ActionError.settingsChangedSinceReview
        }
    }

    /// Applies `plan` and returns the backup file `apply` created, if any.
    private func write(_ plan: InstallPlan) throws -> URL? {
        let directory = paths.settingsURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let before = backups(in: directory)
        try ClaudeSettingsInstaller.apply(plan, to: paths.settingsURL, now: Date())
        return backups(in: directory).subtracting(before).sorted().first.map { directory.appendingPathComponent($0) }
    }

    private func backups(in directory: URL) -> Set<String> {
        let prefix = paths.settingsURL.resolvingSymlinksInPath().lastPathComponent + ".buddy-backup-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    private static func summary(_ action: String, changed: Bool, backup: URL?, settings: URL) -> String {
        guard changed else { return "\(action) \(settings.path) needed no changes." }
        guard let backup else { return "\(action) Wrote \(settings.path) (it did not exist before, so there is no backup)." }
        return "\(action) Updated \(settings.path). Backup: \(backup.path)"
    }

    // MARK: Errors

    static func describe(_ error: Error) -> String {
        switch error {
        case InstallerError.malformedSettings:
            return "The settings file is not valid Claude settings JSON (expected an object with an object `hooks`); nothing was written."
        case let error as ActionError:
            switch error {
            case .settingsChangedSinceReview:
                return "The settings file changed since the preview was made; nothing was written. Review the changes again."
            case .hookBinaryUnavailable:
                return "This build of Buddy has no embedded buddy-hook to install; nothing was written."
            case .unreadableSettings(let detail):
                return "Cannot read \(detail); nothing was written."
            case .invalidConfiguration(let detail):
                return "\(detail) Nothing was read or written."
            case .settingsWriteFailedAfterBinaryInstall(let binary, let reason):
                return "The hook binary was installed at \(binary), but the settings file was NOT changed: \(reason)"
            }
        case let error as HookSocketError:
            switch error {
            case .pathTooLong: return "the socket path is too long"
            case .alreadyStarted: return "the socket server is already running"
            case .notASocket: return "something that is not a socket already exists at the socket path"
            case .addressInUse: return "another Buddy is already listening on the socket"
            case .system(let call, let code): return "\(call) failed (errno \(code))"
            }
        default:
            return error.localizedDescription
        }
    }
}

/// The island reads the model's mirror of the engine and answers through these wrappers (`decide` is above).
extension AppModel: IslandFeed {
    func decidePlan(_ id: UUID, _ choice: PlanChoice) async -> Bool {
        guard let engine else { return false }
        return await engine.decidePlan(requestId: id, choice)
    }

    func answer(_ id: UUID, _ responses: [QuestionResponse]) async -> Bool {
        guard let engine else { return false }
        return await engine.answer(requestId: id, responses)
    }

    func releaseQuestion(_ id: UUID) async {
        await engine?.releaseQuestion(requestId: id)
    }
}
