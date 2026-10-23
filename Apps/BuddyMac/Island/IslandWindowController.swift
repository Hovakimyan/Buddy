import AppKit
import BuddyKit
import Observation
import SwiftUI

/// The island's window: a borderless, non-activating panel that floats over the menu bar on every Space and
/// beside full-screen apps. It never becomes main and takes the keyboard only while the question card's "Other..."
/// field is open (`allowsKey`; being non-activating it does so without activating Buddy); otherwise the hosting view
/// takes the first click instead. It draws nothing of its own (the SwiftUI content draws the shape) and is placed
/// exactly where the controller puts it, over the menu bar and notch.
final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar (`.mainMenu`); menus still open over it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Panels hide when their app is inactive by default; Buddy is almost never the active app.
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// True only while a typed answer is being written.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows below the menu bar by constraining their frame; the island belongs over it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The first click on a button must work although the panel is never key.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the island as a panel above the menu bar: at the notch when the screen has one, a centred bar at the top
/// otherwise. Thin glue: when to show is `IslandMachine`, where and how big is `IslandGeometry`, what the character
/// does is `CharacterDirector` and `IslandLogic`, when to make a sound is `IslandCues`; this class feeds them from
/// the feed, the pointer, the hot keys and the clock, and applies the result to the panel and `IslandUIState`.
///
/// - Hidden: the panel is off screen, so it cannot catch any click.
/// - Compact and expanded: the panel takes the mouse (a click expands it), and is no bigger than what it shows
///   (while the shape shrinks it keeps the larger frame until the animation is over).
@MainActor
final class IslandWindowController {
    /// Opens the settings window. The island has no SwiftUI scene of its own, so the menu-bar label sets this.
    var openSettings: () -> Void = {}

    private let model: AppModel
    /// The feed on screen: `model.islandFeed`, the model's or the demo's (`switchFeed`).
    private var feed: any IslandFeed
    private let hosting: IslandHostingView<IslandView>
    private let ui: IslandUIState
    private let sound: SoundPlayer
    private let panel = IslandPanel()
    private let hotkeys = HotkeyCenter()
    private var cues = IslandCues()
    private var machine = IslandMachine()
    private var director = CharacterDirector()
    private var lastSessions: [Session]?
    private let launchedAt = Date()
    private var hovering = false
    private var characterHovering = false
    private var hoverRect = CGRect.zero
    /// OK'd status cards (`StatusCard.key`).
    private var dismissed: Set<String> = []
    /// Questions the island has drawn that may still get an outcome card (`IslandLogic.shownQuestions`).
    private var shownQuestions: Set<UUID> = []
    /// The app frontmost when the "Other..." field took the keyboard, to give it back to (`IslandLogic.keyboardReturn`).
    private var keyboardOwner: pid_t?
    /// When `machine.closesAt` last changed, so the countdown only shows for a close that was scheduled well ahead.
    private var closeScheduled: (deadline: Date, at: Date)?
    /// One one-shot task, waiting for `machine.closesAt`; `tickDeadline` is the deadline it was made for.
    nonisolated(unsafe) private var tickTask: Task<Void, Never>?
    private var tickDeadline: Date?
    /// The director's 10 Hz clock, running only while the island is on screen.
    nonisolated(unsafe) private var directorTask: Task<Void, Never>?
    /// The mode whose open or close animation has finished: the card's arming clock runs only once it is drawn.
    private var settledMode = IslandMode.hidden
    nonisolated(unsafe) private var settleTask: Task<Void, Never>?
    /// Bumped by every change of shape, so a late animation step or settle of an older change does nothing.
    private var shapeGeneration = 0
    /// Since when the front card has been drawn (`IslandLogic.armingClock`); nil while no card is drawn.
    private var armingClock: ArmingClock?
    nonisolated(unsafe) private var armTask: Task<Void, Never>?
    private var armTaskClock: ArmingClock?
    // Unsafe only so `deinit` can release them; everything else touches them on the main actor.
    nonisolated(unsafe) private var monitors: [Any] = []
    nonisolated(unsafe) private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var screensSleptAt: Date?
    private var started = false

    private static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.74)
    private static let closeAnimation = Animation.easeInOut(duration: 0.34)
    private static let fadeAnimation = Animation.easeInOut(duration: 0.2)

    init(model: AppModel, sound: SoundPlayer? = nil) {
        let feed = model.islandFeed
        let ui = IslandUIState()
        self.model = model
        self.feed = feed
        self.ui = ui
        self.sound = sound ?? .shared
        hosting = IslandHostingView(rootView: IslandView(feed: feed, ui: ui))
        hosting.sizingOptions = []
        // Inside a plain container rather than as the content view: the panel's frame changes while SwiftUI animates,
        // and a hosting content view would also keep the window's content size limits in step with every pass.
        let container = NSView()
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.ignoresMouseEvents = true
    }

    /// Freed without `stop()`: no clock, monitor or observer outlives the controller (the hot keys go with
    /// `HotkeyCenter`'s own deinit).
    deinit {
        for task in [tickTask, directorTask, settleTask, armTask] { task?.cancel() }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    func start() {
        guard !started else { return }
        started = true
        ui.character = CharacterRegistry.current(defaults: .standard)
        ui.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ui.muted = sound.isMuted
        ui.onClick = { [weak self] in self?.send(.click) }
        ui.onCharacterClick = { [weak self] in self?.characterClicked() }
        ui.onFocus = { [weak self] id in self?.focus(id) }
        ui.onToggleMute = { [weak self] in self?.toggleMute() }
        ui.onOpenSettings = { [weak self] in self?.openSettings() }
        ui.onClose = { [weak self] in self?.send(.escape) }
        ui.onDismissStatus = { [weak self] key in self?.dismissStatus(key) }
        ui.onChoice = { [weak self] approval, choice in self?.choose(choice, for: approval) }
        ui.onPlanChoice = { [weak self] approval, choice in self?.choosePlan(choice, for: approval) }
        ui.onQuestion = { [weak self] event in self?.question(event) }

        hotkeys.onAction = { [weak self] action in self?.hotkey(action) }
        hotkeys.start()
        for hotkey in Hotkeys.global { hotkeys.register(hotkey) }

        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.apply() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.ui.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensSleptAt = Date() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensWoke() }
        observe(NotificationCenter.default, NSWindow.didResignKeyNotification, object: panel) { $0.panelResignedKey() }
        // The pointer decides "hovering": a global monitor sees it while other apps are active (and needs no
        // permission for mouse moves), a local one while Buddy is.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(local) }

        // Hello at launch: the island shows compact while the character drops in.
        director.greet(now: launchedAt)
        handle(.ordinaryEvent)
        trackAndRefresh()
    }

    /// Removes the hot keys, monitors and observers, stops every clock and takes the panel off screen. The app calls
    /// this when it quits.
    func stop() {
        started = false
        setTyping(false)
        hotkeys.stop()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        cancelArmTask()
        cancelTickTask()
        directorTask?.cancel()
        directorTask = nil
        settleTask?.cancel()
        settleTask = nil
        panel.orderOut(nil)
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
        _ action: @escaping @MainActor @Sendable (IslandWindowController) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, observer))
    }

    // MARK: Updating

    /// Runs `refresh` now and again whenever the feed on screen (sessions, cards), which feed that is (the demo
    /// starting or ending) or mute changes. Only those are tracked: the island's own state changes all the time and
    /// is applied where it changes.
    private func trackAndRefresh() {
        guard started else { return }
        withObservationTracking {
            let feed = model.islandFeed
            _ = (feed.sessions, feed.pending, feed.questions, feed.questionOutcomes, sound.isMuted)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackAndRefresh() }
        }
        refresh()
    }

    /// Shows `next` (the demo, or the model again after it) in place of the feed on screen, starting again from
    /// `IslandLogic.afterFeedSwitch` (the cue baseline, no chosen session, no questions shown).
    private func switchFeed(to next: any IslandFeed) {
        feed = next
        hosting.rootView = IslandView(feed: next, ui: ui)
        let reset = IslandLogic.afterFeedSwitch(toModel: next === model, modelSessions: model.sessions, cues: cues)
        cues = reset.cues
        ui.chosenSession = reset.chosenSession
        shownQuestions = reset.shownQuestions
    }

    private var demoShowing: Bool { feed !== model }

    private func refresh() {
        let current = model.islandFeed
        if current !== feed { switchFeed(to: current) }
        let sessions = feed.sessions
        let pending = feed.pending
        let snapshot = EngineSnapshot(sessions: sessions, pending: pending, questions: feed.questions)
        let terminalFrontmost = IslandLogic.cuesSeeTerminalFrontmost(
            demo: demoShowing,
            terminalFrontmost: TerminalApps.isTerminal(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
        for cue in cues.snapshot(snapshot, terminalFrontmost: terminalFrontmost) { sound.play(cue) }
        if sound.isMuted != ui.muted { ui.muted = sound.isMuted }
        if IslandLogic.sessionsChanged(previous: lastSessions, current: sessions) { handle(.ordinaryEvent) }
        handle(.waitingCards(Set(pending.map(\.id) + feed.questions.map(\.id))))
        // Drawn ones are added by `trackCard`; here those neither waiting nor lately resolved go.
        shownQuestions = IslandLogic.shownQuestions(
            shownQuestions, drawn: nil, questions: feed.questions, outcomes: feed.questionOutcomes)
        lastSessions = sessions
        updateCharacter(now: Date())
        apply()
    }

    /// Feeds one input to the machine, plays the change's sounds and applies the result.
    private func send(_ input: IslandInput) {
        handle(input)
        apply()
    }

    private func handle(_ input: IslandInput) {
        guard let transition = machine.handle(input, now: Date()) else { return }
        for cue in IslandLogic.cues(for: transition) { sound.play(cue) }
        // Escape on the open island with a question in front: the terminal asks it now.
        if let id = IslandLogic.questionToRelease(after: transition, front: front) { release(id) }
    }

    /// The card the expanded island shows (oldest first across approvals and questions).
    private var front: FrontCard? { IslandLogic.frontCard(pending: feed.pending, questions: feed.questions) }

    private var focused: Session? {
        IslandLogic.focusedSession(
            sessions: feed.sessions, pending: feed.pending, questions: feed.questions, chosen: ui.chosenSession)
    }

    /// Puts the panel, the shape, the view's mode, Escape and the clocks in line with the machine.
    private func apply() {
        let mode = machine.mode
        let placement = IslandGeometry.placement(for: Self.metrics(of: Self.chosenScreen()))
        if ui.placement != placement { ui.placement = placement }
        updateStatusCard()
        syncQuestionCard()
        let content = IslandContent(
            otherSessions: IslandLogic.otherSessions(feed.sessions, focused: focused?.id).count, card: contentCard(),
            agents: focused?.agents.count ?? 0)
        let compact = IslandGeometry.panelSize(mode: .compact, content: content, placement: placement)
        let expanded = IslandGeometry.panelSize(mode: .expanded, content: content, placement: placement)
        let resting = IslandGeometry.restingSize(placement: placement)
        let target = switch mode {
        case .hidden: resting
        case .compact: compact
        case .expanded: expanded
        }
        let radius = Self.cornerRadius(mode)
        let frame = IslandGeometry.panelFrame(size: target, placement: placement)
        hoverRect = IslandGeometry.hoverRect(mode: mode, panelFrame: frame, placement: placement)

        updateKeys()
        if let deadline = machine.closesAt {
            if closeScheduled?.deadline != deadline { closeScheduled = (deadline, Date()) }
        } else {
            closeScheduled = nil
        }
        scheduleTick()
        runDirector(IslandLogic.directorRuns(mode: mode))
        if mode != .expanded { settledMode = mode }
        defer { trackCard(mode: settledMode) }

        let from = ui.mode
        guard from != mode || ui.shapeSize != target || ui.cornerRadius != radius || ui.compactSize != compact
            || ui.expandedSize != expanded || (mode != .hidden && !panel.isVisible)
        else { return }
        shapeGeneration += 1
        let generation = shapeGeneration
        panel.ignoresMouseEvents = mode == .hidden
        let growing = Self.rank(mode) > Self.rank(from)
            || (mode == from && target.width >= ui.shapeSize.width && target.height >= ui.shapeSize.height)

        if mode != .hidden && (from == .hidden || !panel.isVisible) {
            // Appearing: the shape starts as the notch, drawn once, and grows out of it on the next turn.
            withoutAnimation {
                ui.shapeSize = resting
                ui.cornerRadius = Self.cornerRadius(.hidden)
                ui.compactSize = compact
                ui.expandedSize = expanded
            }
            panel.setFrame(IslandGeometry.panelFrame(size: target, placement: placement), display: true)
            panel.orderFrontRegardless()
            Task { @MainActor [weak self] in
                guard let self, self.shapeGeneration == generation else { return }
                self.animate(mode: mode, shape: target, radius: radius, compact: compact, expanded: expanded, growing: true)
            }
            return
        }
        if growing {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        } else {
            // Shrinking: keep the frame (it holds the larger shape) until the animation is over.
            let union = panel.frame.union(frame)
            if panel.frame != union { panel.setFrame(union, display: true) }
        }
        animate(mode: mode, shape: target, radius: radius, compact: compact, expanded: expanded, growing: growing)
    }

    /// Moves the shape and the content to `mode`: a spring with a slight overshoot opening, an ease-in-out closing,
    /// the content cross-fading meanwhile. Under Reduce Motion the shape jumps and the content only fades.
    private func animate(
        mode: IslandMode, shape: CGSize, radius: CGFloat, compact: CGSize, expanded: CGSize, growing: Bool
    ) {
        let generation = shapeGeneration
        let duration: TimeInterval
        if ui.reduceMotion {
            withoutAnimation {
                ui.shapeSize = shape
                ui.cornerRadius = radius
                ui.compactSize = compact
                ui.expandedSize = expanded
            }
            withAnimation(Self.fadeAnimation) { ui.mode = mode }
            duration = 0.22
        } else {
            withAnimation(growing ? Self.openAnimation : Self.closeAnimation) {
                ui.mode = mode
                ui.shapeSize = shape
                ui.cornerRadius = radius
                ui.compactSize = compact
                ui.expandedSize = expanded
            }
            duration = growing ? 0.45 : 0.36
        }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.shapeGeneration == generation else { return }
            self.settle()
        }
    }

    /// After an animation: the panel takes the final size (or leaves the screen), and a card now fully drawn starts
    /// its arming clock.
    private func settle() {
        let mode = machine.mode
        settledMode = mode
        if mode == .hidden {
            panel.orderOut(nil)
        } else {
            let frame = IslandGeometry.panelFrame(size: ui.shapeSize, placement: ui.placement)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }
        trackCard(mode: settledMode)
    }

    /// What the expanded island holds under the pills, for its height.
    private func contentCard() -> IslandContent.Card {
        switch front {
        case .approval(let approval):
            switch approval.kind {
            case .tool: return .approval(lines: IslandLogic.cardLines(for: approval))
            case .plan: return .plan(height: PlanCardView.naturalHeight(for: approval))
            }
        case .question:
            return .question(height: ui.questionCard?.naturalHeight ?? 0)
        case nil:
            return ui.statusCard == nil ? .none : .status
        }
    }

    /// Gives the front question its card state (a fresh one for a new question) and drops it when no question is in
    /// front, closing the field (and giving the keyboard back) with it.
    private func syncQuestionCard() {
        guard case .question(let question)? = front else {
            if ui.questionCard != nil { ui.questionCard = nil }
            setTyping(false)
            return
        }
        guard ui.questionCard?.id != question.id else { return }
        var card = QuestionCardModel(question: question)
        card.shownAt = armingClock?.request == question.id ? armingClock?.since : nil
        ui.questionCard = card
        setTyping(false)
    }

    /// Takes Escape (a global key) only while the island is expanded and the pointer is on it, and 1-4 only while a
    /// question is in front too; gives them back as soon as that stops, and while the "Other..." field has the
    /// keyboard (they are its keys then). Checked on every `apply`, every pointer move and when the field opens or closes.
    private func updateKeys() {
        let inside = IslandGeometry.isInside(NSEvent.mouseLocation, hoverRect)
        let typing = ui.questionCard?.otherText != nil
        if Hotkeys.wantsEscape(mode: machine.mode, pointerInside: inside, typing: typing) {
            hotkeys.register(Hotkeys.escape)
        } else {
            hotkeys.unregister(Hotkeys.escape)
        }
        var questionFront = false
        if case .question? = front { questionFront = true }
        let digits = Hotkeys.wantsDigits(
            mode: machine.mode, pointerInside: inside, questionFront: questionFront, typing: typing)
        for digit in Hotkeys.digits {
            if digits { hotkeys.register(digit) } else { hotkeys.unregister(digit) }
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    private static func rank(_ mode: IslandMode) -> Int {
        switch mode {
        case .hidden: 0
        case .compact: 1
        case .expanded: 2
        }
    }

    private static func cornerRadius(_ mode: IslandMode) -> CGFloat {
        switch mode {
        case .hidden: 10
        case .compact: 12
        case .expanded: 24
        }
    }

    // MARK: Character

    /// Ticks the director every 100 ms while the island is on screen; stopped while it is hidden.
    private func runDirector(_ run: Bool) {
        guard run else {
            directorTask?.cancel()
            directorTask = nil
            return
        }
        guard directorTask == nil else { return }
        directorTask = Task { [weak self] in
            while !Task.isCancelled {
                // Holds the controller only for the tick, never across the sleep, and ends once it is gone.
                do {
                    guard let self else { return }
                    self.directorTick()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func directorTick() {
        let now = Date()
        for event in director.tick(now: now) {
            if let cue = IslandLogic.cue(for: event) { sound.play(cue) }
        }
        updateCharacter(now: now)
        if updateStatusCard() { apply() }
        updateCountdown(now: now)
    }

    /// The character's state and the director's reactions into `ui.face`; `sleep` on falling asleep.
    private func updateCharacter(now: Date) {
        let lastEvent = max(IslandLogic.quietSince(demo: demoShowing, launchedAt: launchedAt), feed.sessions.map(\.updatedAt).max() ?? launchedAt)
        let state = IslandLogic.characterState(
            focused: focused, pending: feed.pending, questions: feed.questions,
            quietFor: now.timeIntervalSince(lastEvent), visible: machine.mode != .hidden,
            dizzy: director.dizzyUntil != nil)
        var face = ui.face
        if face.state != state {
            face.state = state
            face.stateStartedAt = now
            for cue in cues.character(state) { sound.play(cue) }
        }
        face.emote = director.emote?.0
        face.emoteStartedAt = director.emote?.1
        face.boopedAt = director.boopedAt
        face.greetingStartedAt = director.greetingStartedAt
        face.hovering = director.hovering
        if face != ui.face { ui.face = face }
    }

    /// Whether the status card changed.
    @discardableResult
    private func updateStatusCard() -> Bool {
        let card = IslandLogic.statusCard(
            focused: focused, dizzy: director.dizzyUntil != nil,
            cardPending: !feed.pending.isEmpty || !feed.questions.isEmpty, dismissed: dismissed,
            outcome: IslandLogic.outcomeCard(feed.questionOutcomes, shown: shownQuestions, now: Date()))
        guard card != ui.statusCard else { return false }
        ui.statusCard = card
        return true
    }

    /// The line runs out over the last 5 s before a close that was scheduled at least 10 s ahead.
    private func updateCountdown(now: Date) {
        var left: Double?
        if let scheduled = closeScheduled, scheduled.deadline.timeIntervalSince(scheduled.at) >= 10 {
            let remaining = scheduled.deadline.timeIntervalSince(now)
            if remaining <= 5 { left = max(0, remaining / 5) }
        }
        if left != ui.countdown { ui.countdown = left }
    }

    private func characterClicked() {
        guard machine.mode == .expanded else {
            send(.click)
            return
        }
        director.click(now: Date())
        send(.interaction)
        directorTick()
    }

    private func screensWoke() {
        let now = Date()
        defer { screensSleptAt = nil }
        guard let slept = screensSleptAt else { return }
        let before = director.greetingStartedAt
        director.screenAway(from: slept, to: now)
        if director.greetingStartedAt != before { send(.ordinaryEvent) }
    }

    // MARK: Actions

    private func focus(_ id: String) {
        ui.chosenSession = id
        sound.play(.switchSession)
        send(.interaction)
    }

    /// `SoundPlayer.setMuted` ticks while sound is still (or again) on, so it is heard either way.
    private func toggleMute() {
        sound.setMuted(!sound.isMuted)
        ui.muted = sound.isMuted
    }

    private func dismissStatus(_ key: String) {
        dismissed.insert(key)
        apply()
    }

    /// Deny is never delayed: it works while the card has no arming clock yet. Allow and Always wait for it.
    private func choose(_ choice: ApprovalChoice, for approval: PendingApproval) {
        guard let decision = IslandLogic.decision(
            for: choice, approval: approval, shownAt: ui.shownAt[approval.id], now: Date())
        else { return }
        // The feed the card was drawn from, so a demo card's id never reaches the model (nor a real one the demo).
        let feed = feed
        Task { [weak self] in
            guard let self else { return }
            let sent = await feed.decide(approval.id, decision)
            if sent && decision == .allow { self.sound.play(.approve) }
        }
    }

    /// "Change plan" is never delayed; the Go buttons wait for the arming clock, like Allow.
    private func choosePlan(_ choice: PlanChoice, for approval: PendingApproval) {
        guard let choice = IslandLogic.planChoice(choice, shownAt: ui.shownAt[approval.id], now: Date()) else { return }
        let feed = feed
        Task { [weak self] in
            guard let self else { return }
            let sent = await feed.decidePlan(approval.id, choice)
            if sent && choice != .change { self.sound.play(.approve) }
        }
    }

    /// A control of the question card (or a key 1-4): updates the card and sends the answers once complete.
    private func question(_ event: QuestionCardEvent) {
        guard var card = ui.questionCard else { return }
        let now = Date()
        let action: CardAction
        switch event {
        case .pick(let label): action = card.pick(label, now: now)
        case .number(let place): action = card.pressNumber(place, now: now)
        case .next: action = card.next(now: now)
        case .openOther:
            card.openOther()
            action = .none
        case .cancelOther:
            card.cancelOther()
            action = .none
        case .answerInTerminal:
            release(card.id)
            return
        }
        if card != ui.questionCard { ui.questionCard = card }
        setTyping(card.otherText != nil)
        switch action {
        case .advanced:
            // The next question is armed afresh (the card's model refuses picks until then): its options dim again.
            if armingClock?.request == card.id { armingClock = ArmingClock(request: card.id, since: now) }
        case .send(let responses):
            let id = card.id
            let feed = feed
            Task { [weak self] in
                guard let self else { return }
                // Only an answer the engine took (and will send) is heard; after a refused one the card takes picks
                // again until it goes.
                if await feed.answer(id, responses) {
                    self.sound.play(.approve)
                } else if self.ui.questionCard?.id == id {
                    self.ui.questionCard?.answerRefused()
                }
            }
        case .none:
            break
        }
        send(.interaction)
    }

    /// "Answer in terminal", or Escape on the open island: the hook prints nothing and the terminal asks.
    private func release(_ id: UUID) {
        let feed = feed
        Task { await feed.releaseQuestion(id) }
    }

    /// The panel takes the keyboard while the "Other..." field is open (so the field can be typed in) and gives it
    /// back when the field closes: the panel can no longer be key, and the app that was frontmost when the field
    /// opened is activated again (nothing when that was Buddy or none). Never `resignKey()`, which only reports.
    private func setTyping(_ typing: Bool) {
        guard typing != panel.allowsKey else { return }
        panel.allowsKey = typing
        if typing {
            keyboardOwner = IslandLogic.keyboardReturn(
                frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                own: ProcessInfo.processInfo.processIdentifier)
            panel.makeKey()
        } else {
            let owner = keyboardOwner
            keyboardOwner = nil
            if panel.isKeyWindow, let owner, let app = NSRunningApplication(processIdentifier: owner) {
                app.activate(options: [])
            }
        }
        updateKeys()
    }

    /// The person clicked elsewhere while typing: the field closes (its text is dropped, nothing is answered) so the
    /// keys follow the usual rules again. The keyboard is where they clicked; it is not handed back.
    private func panelResignedKey() {
        guard panel.allowsKey else { return }
        keyboardOwner = nil
        if ui.questionCard?.otherText != nil { ui.questionCard?.cancelOther() }
        setTyping(false)
        apply()
    }

    private func hotkey(_ action: HotkeyAction) {
        switch action {
        case .toggleMute:
            toggleMute()
        case .nextSession, .previousSession:
            // Nothing (and no sound) when the focus cannot move, e.g. while a card holds it on its session.
            guard let next = IslandLogic.cycledFocus(
                sessions: feed.sessions, pending: feed.pending, questions: feed.questions, chosen: ui.chosenSession,
                forward: action == .nextSession)
            else { return }
            ui.chosenSession = next
            sound.play(.switchSession)
            handle(.ordinaryEvent)
            send(.interaction)
        case .showPending:
            // Expanded, the front card is the one drawn, and its session has the focus.
            send(.click)
        case .escape:
            send(.escape)
        case .pick(let place):
            question(.number(place))
        }
    }

    // MARK: Arming and closing

    /// Waits, in one task at a time, for `machine.closesAt` and then sends `.tick`. No polling.
    private func scheduleTick() {
        guard let deadline = machine.closesAt else {
            cancelTickTask()
            return
        }
        guard tickDeadline != deadline else { return }
        tickTask?.cancel()
        tickDeadline = deadline
        tickTask = Task { [weak self] in
            // A wake-up a hair early just sleeps the rest.
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled, let self, self.tickDeadline == deadline else { return }
            self.tickDeadline = nil
            self.tickTask = nil
            self.send(.tick)
        }
    }

    private func cancelTickTask() {
        tickTask?.cancel()
        tickTask = nil
        tickDeadline = nil
    }

    /// Runs the front card's arming clock while the card is drawn (`IslandLogic.armingClock`: it starts, and
    /// starts again, whenever the card comes into sight) and arms the card (Allow/Always start working)
    /// `IslandLogic.armingDelay` after the clock started. One one-shot task at a time, cancelled when the card
    /// goes out of sight or away. "Drawn" is the settled mode: the card counts once the island has finished opening.
    private func trackCard(mode: IslandMode) {
        let now = Date()
        let clock = IslandLogic.armingClock(front: front?.id, mode: mode, previous: armingClock, now: now)
        armingClock = clock
        let shownAt = clock.map { [$0.request: $0.since] } ?? [:]
        if ui.shownAt != shownAt { ui.shownAt = shownAt }
        if var card = ui.questionCard {
            card.shownAt = clock?.request == card.id ? clock?.since : nil
            if card != ui.questionCard { ui.questionCard = card }
        }
        shownQuestions = IslandLogic.shownQuestions(
            shownQuestions, drawn: clock?.request, questions: feed.questions, outcomes: feed.questionOutcomes)
        guard let clock else {
            cancelArmTask()
            if ui.armedRequest != nil { ui.armedRequest = nil }
            return
        }
        if IslandLogic.isArmed(shownAt: clock.since, now: now) {
            cancelArmTask()
            if ui.armedRequest != clock.request { ui.armedRequest = clock.request }
            return
        }
        if ui.armedRequest != nil { ui.armedRequest = nil }
        guard armTaskClock != clock else { return }
        cancelArmTask()
        armTaskClock = clock
        armTask = Task { [weak self] in
            // Sleep until the card is armed; a wake-up a hair early just sleeps the rest.
            while !Task.isCancelled {
                let remaining = clock.since.addingTimeInterval(IslandLogic.armingDelay).timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled, let self, self.armTaskClock == clock else { return }
            self.armTaskClock = nil
            self.armTask = nil
            if self.armingClock == clock { self.ui.armedRequest = clock.request }
        }
    }

    private func cancelArmTask() {
        armTask?.cancel()
        armTask = nil
        armTaskClock = nil
    }

    // MARK: Pointer

    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        let inside = IslandGeometry.isInside(location, hoverRect)
        if inside != hovering {
            hovering = inside
            send(inside ? .hoverBegan : .hoverEnded)
        } else if inside && machine.mode == .expanded {
            send(.interaction)
        }
        updateKeys()
        trackCharacterHover(location)
    }

    /// The character's hover (the director's long-hover love) and where it looks, from the pointer relative to it.
    private func trackCharacterHover(_ location: CGPoint) {
        let now = Date()
        guard machine.mode != .hidden, panel.isVisible, !ui.characterFrame.isEmpty else {
            if characterHovering {
                characterHovering = false
                director.hoverEnded(now: now)
            }
            return
        }
        // Panel coordinates with the origin at the top left, like the SwiftUI frame.
        let point = CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
        let frame = ui.characterFrame
        let over = frame.insetBy(dx: -4, dy: -4).contains(point)
        if over != characterHovering {
            characterHovering = over
            if over {
                director.hoverBegan(at: point, now: now)
                sound.play(.hover)
            } else {
                director.hoverEnded(now: now)
            }
        } else if over {
            director.hoverMoved(to: point, now: now)
        }
        let look = CGVector(
            dx: min(max((point.x - frame.midX) / 150, -1), 1), dy: min(max((point.y - frame.midY) / 150, -1), 1))
        if abs(look.dx - ui.look.dx) > 0.03 || abs(look.dy - ui.look.dy) > 0.03 { ui.look = look }
    }

    // MARK: Screens

    /// The screen `IslandGeometry.chooseScreen` picks among the connected ones (a candidate's id is its index in
    /// `NSScreen.screens`), or nil when there is none.
    private static func chosenScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let main = NSScreen.main
        let candidates = screens.enumerated().map { index, screen in
            ScreenCandidate(id: index, hasNotch: screen.safeAreaInsets.top > 0, isMain: screen == main)
        }
        guard let id = IslandGeometry.chooseScreen(candidates), screens.indices.contains(id) else { return nil }
        return screens[id]
    }

    /// What the geometry needs from `screen`. The menu bar's height is the live gap above `visibleFrame` (0 when
    /// the menu bar is auto-hidden) on a screen without a notch, and the system status bar's thickness on one
    /// with a notch (where the notch sets the height). Without a screen, a plain laptop-sized one, so the island
    /// still lays out.
    private static func metrics(of screen: NSScreen?) -> ScreenMetrics {
        guard let screen else {
            return ScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0,
                auxiliaryLeft: nil, auxiliaryRight: nil, menuBarHeight: NSStatusBar.system.thickness)
        }
        let frame = screen.frame
        let safeAreaTop = screen.safeAreaInsets.top
        let menuBarHeight = safeAreaTop > 0
            ? NSStatusBar.system.thickness
            : max(0, frame.maxY - screen.visibleFrame.maxY)
        return ScreenMetrics(
            frame: frame, safeAreaTop: safeAreaTop,
            auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea,
            menuBarHeight: menuBarHeight)
    }
}
