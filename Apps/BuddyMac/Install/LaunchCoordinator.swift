import Foundation

/// How the person is asked about the move, and told when it fails. An alert in the app, a fake in tests.
@MainActor
protocol MovePresenting {
    /// True when the person agrees to the move.
    func confirmMove(_ offer: MoveToApplications.Offer) -> Bool
    func showMoveFailure(_ message: String)
}

/// What happens once at launch, in order: offer to move the app to Applications, then (first launch, or outdated
/// hooks) open the setup window. The order matters: an instance that moves itself quits without using up the
/// setup window, so the copy in Applications shows it. The setup window's first step offers the same move again
/// (`moveToApplications`). Every input is injected; tests never show an alert, copy into the real `/Applications` or
/// quit anything.
@MainActor
final class LaunchCoordinator {
    private let model: AppModel
    private let presenter: any MovePresenting
    private let others: OtherInstances
    /// How long a running older Buddy gets to quit before the move is given up.
    private let quitTimeout: Duration
    /// Copies the app (see `MoveToApplications.copy`).
    private let copy: (URL, URL) throws -> Void
    /// Opens the copy once this process is gone and quits this one.
    private let relaunch: @MainActor (URL) throws -> Void
    private let bundleURL: URL
    private let environment: [String: String]
    private let home: URL
    private let isUnderTests: Bool
    private let originalLocation: (URL) -> URL?
    private let exists: (String) -> Bool
    private var hasRun = false

    init(
        model: AppModel,
        presenter: any MovePresenting,
        relaunch: @escaping @MainActor (URL) throws -> Void,
        others: OtherInstances = .live,
        quitTimeout: Duration = .seconds(10),
        copy: @escaping (URL, URL) throws -> Void = MoveToApplications.copy,
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isUnderTests: Bool? = nil,
        originalLocation: @escaping (URL) -> URL? = Translocation.originalLocation(of:),
        exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.model = model
        self.presenter = presenter
        self.others = others
        self.quitTimeout = quitTimeout
        self.relaunch = relaunch
        self.copy = copy
        self.bundleURL = bundleURL
        self.environment = environment
        self.home = home
        self.isUnderTests = isUnderTests ?? MoveToApplications.isUnderTests(environment: environment)
        self.originalLocation = originalLocation
        self.exists = exists
    }

    /// Runs the launch steps once; a second call does nothing. `openSetup` shows the setup window.
    func run(openSetup: () -> Void) async {
        guard !hasRun else { return }
        hasRun = true
        model.inApplications = !wouldOfferMove
        if await offerMove() { return }
        if model.shouldOpenSetupAtLaunch() { openSetup() }
    }

    /// The setup window's "Move to Applications": the same alert and move as at launch. The copy reopens the window.
    func moveToApplications() async {
        _ = await offerMove(fromSetupWindow: true)
    }

    /// True when Buddy runs from a place it should be moved from (the move would be offered).
    private var wouldOfferMove: Bool {
        if case .offer = decision(otherInstanceRunning: false) { return true }
        return false
    }

    private func decision(otherInstanceRunning: Bool) -> MoveToApplications.Decision {
        MoveToApplications.decide(
            bundleURL: bundleURL, environment: environment, isUnderTests: isUnderTests, home: home,
            otherInstanceRunning: otherInstanceRunning, originalLocation: originalLocation, exists: exists)
    }

    /// True when the app was copied and is being replaced by the copy (so nothing else should happen here).
    /// A declined offer, an older Buddy that will not quit, a failed copy and a failed relaunch all return false: the app keeps running where it is.
    private func offerMove(fromSetupWindow: Bool = false) async -> Bool {
        guard case .offer(let offer) = decision(otherInstanceRunning: others.isRunning), presenter.confirmMove(offer)
        else { return false }
        // A bundle is never replaced under a running process: an older Buddy has to be gone first.
        if offer.otherInstanceRunning, !(await others.quitAndWait(timeout: quitTimeout)) {
            presenter.showMoveFailure(
                "The Buddy that is already running did not quit, so nothing was moved. Quit it from its menu and try again. This one keeps running from where it is.")
            return false
        }
        do {
            try copy(offer.source, offer.destination)
        } catch {
            presenter.showMoveFailure(
                "Buddy could not be copied to \(offer.destination.path): \(error.localizedDescription) It keeps running from where it is.")
            return false
        }
        // Cleared just before the relaunch, so the copy opens the window; put back if this instance keeps running.
        if fromSetupWindow { model.setupWillRelaunch() }
        do {
            try relaunch(offer.destination)
        } catch {
            if fromSetupWindow { model.setupWindowDidAppear() }
            presenter.showMoveFailure(
                "Buddy was copied to \(offer.destination.path) but could not be opened from there: \(error.localizedDescription) Open it from Applications yourself.")
            return false
        }
        return true
    }
}
