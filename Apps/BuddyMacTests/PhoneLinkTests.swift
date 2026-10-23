import BuddyKit
import Foundation
import Synchronization
import Testing

// SAFETY: no test creates a CKContainer, contacts CloudKit, or touches ~/.claude or
// ~/Library/Application Support/Buddy. Sockets are in /tmp, the transport talks to FakeCloudDatabase.

/// Counts what the injected closures were asked to do.
private final class Calls: Sendable {
    private let state = Mutex((entitlement: 0, account: 0, transport: 0))
    var entitlement: Int { state.withLock { $0.entitlement } }
    var account: Int { state.withLock { $0.account } }
    var transport: Int { state.withLock { $0.transport } }

    func selector(entitled: Bool, account: PhoneLinkAccount) -> PhoneLinkSelector {
        PhoneLinkSelector(
            hasEntitlement: { () -> Bool in
                self.state.withLock { $0.entitlement += 1 }
                return entitled
            },
            account: { () -> PhoneLinkAccount in
                self.state.withLock { $0.account += 1 }
                return account
            },
            makeTransport: { () -> CloudKitTransport in
                self.state.withLock { $0.transport += 1 }
                return CloudKitTransport(role: .mac, database: FakeCloudDatabase())
            })
    }
}

@Suite struct PhoneLinkSelectionTests {
    @Test func noEntitlementMeansNoTransportAndNoCloudKitCall() async {
        let calls = Calls()
        let link = await calls.selector(entitled: false, account: .available).select()
        #expect(link.transport == nil)
        guard case .off(let reason) = link.status else {
            Issue.record("expected off, got \(link.status)")
            return
        }
        #expect(reason.contains("entitlement"))
        #expect(calls.account == 0)  // the account (and so any CKContainer) is never touched
        #expect(calls.transport == 0)
    }

    @Test func availableAccountGetsATransport() async {
        let calls = Calls()
        let link = await calls.selector(entitled: true, account: .available).select()
        #expect(link.transport != nil)
        #expect(link.status == .on)
        #expect(calls.transport == 1)
    }

    @Test func unavailableAccountsFallBackWithAReason() async {
        let cases: [(PhoneLinkAccount, String)] = [
            (.noAccount, "not signed in"), (.restricted, "restricted"), (.temporarilyUnavailable, "temporarily"),
            (.couldNotDetermine, "could not determine"), (.failed("offline"), "offline"),
        ]
        for (account, fragment) in cases {
            let calls = Calls()
            let link = await calls.selector(entitled: true, account: account).select()
            #expect(link.transport == nil, "\(account)")
            guard case .off(let reason) = link.status else { Issue.record("expected off for \(account)"); continue }
            #expect(reason.contains(fragment), "\(account): \(reason)")
            #expect(calls.transport == 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aCheckThatNeverReturnsTimesOutAndStatesWhy() async {
        let calls = Calls()
        var selector = calls.selector(entitled: true, account: .available)
        selector.account = { await withUnsafeContinuation { (_: UnsafeContinuation<PhoneLinkAccount, Never>) in } }
        selector.accountTimeout = .milliseconds(100)
        let link = await selector.select()
        #expect(link.transport == nil)
        #expect(link.status == .off(reason: "iCloud check timed out; trying again"))
        #expect(link.retryable)
        #expect(calls.transport == 0)
    }

    @Test func onlyAnswersThatCanChangeByThemselvesAreRetried() async {
        let retried: [PhoneLinkAccount] = [.noAccount, .temporarilyUnavailable, .couldNotDetermine, .timedOut, .failed("x")]
        for account in retried {
            #expect(await Calls().selector(entitled: true, account: account).select().retryable, "\(account)")
        }
        #expect(await !Calls().selector(entitled: true, account: .restricted).select().retryable)
        #expect(await !Calls().selector(entitled: true, account: .available).select().retryable)
        #expect(await !Calls().selector(entitled: false, account: .timedOut).select().retryable)
    }

    @Test func retryDelaysGrowThenRepeatTheLast() {
        let selector = Calls().selector(entitled: true, account: .available)
        #expect(selector.retryDelay(attempt: 0) == .seconds(10))
        #expect(selector.retryDelay(attempt: 4) == .seconds(300))
        #expect(selector.retryDelay(attempt: 40) == .seconds(300))
    }

    @Test func aFastCheckIsNotDelayedByTheTimeout() async {
        let calls = Calls()
        var selector = calls.selector(entitled: true, account: .available)
        selector.accountTimeout = .seconds(60)
        let started = ContinuousClock.now
        let link = await selector.select()
        #expect(link.status == .on)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func statusTextIsANonErrorSentence() {
        #expect(PhoneLinkStatus.on.text == "Phone link on")
        #expect(PhoneLinkStatus.off(reason: "not signed in to iCloud").text == "Phone link off: not signed in to iCloud")
        #expect(PhoneLinkStatus.checking.text.hasPrefix("Phone link"))
    }
}

/// Whether each engine the model built was given a transport.
private final class Received: Sendable {
    private let state = Mutex<[Bool]>([])
    func append(_ value: Bool) { state.withLock { $0.append(value) } }
    var values: [Bool] { state.withLock { $0 } }
}

private final class Flag: Sendable {
    private let state = Mutex(false)
    var value: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// The `--ask` hook for one single-select question (Red or Blue), blocking until it is answered; returns what it printed.
private func askClient(socket: URL) -> String? {
    let input: JSONValue = .object(["questions": .array([.object([
        "question": .string("Which color?"), "header": .string("Color"),
        "options": .array([.object(["label": .string("Red")]), .object(["label": .string("Blue")])]),
    ])])])
    let event: JSONValue = .object([
        "session_id": .string("s1"), "hook_event_name": .string("PreToolUse"),
        "tool_name": .string("AskUserQuestion"), "tool_input": input,
    ])
    let data = try! JSONEncoder().encode(event)
    return HookClient.run(input: data, socketPath: socket, ask: true, connectTimeout: 5, waitTimeout: 25)
}

@MainActor
@Suite struct AppModelPhoneLinkTests {
    private func socketURL() -> URL {
        URL(fileURLWithPath: "/tmp/buddy-p\(UUID().uuidString.prefix(8).lowercased()).sock")
    }

    private func paths() -> AppModel.Paths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-pl-\(UUID().uuidString)")
        return AppModel.Paths(
            settingsURL: root.appendingPathComponent("settings.json"),
            supportDirectory: root.appendingPathComponent("support"), hookBinarySource: nil)
    }

    /// Builds a model whose engine is made through `makeEngine`; records whether it got a transport.
    private func model(_ selector: PhoneLinkSelector, socket: URL, received: Received) -> AppModel {
        AppModel(
            selector: selector,
            makeEngine: { transport, _ in
                received.append(transport != nil)
                return BuddyEngine(socketPath: socket, transport: transport)
            },
            paths: paths())
    }

    @Test func withoutEntitlementTheAppRunsMacOnlyAndSaysWhy() async {
        let calls = Calls()
        let received = Received()
        let model = model(calls.selector(entitled: false, account: .available), socket: socketURL(), received: received)
        #expect(model.phoneLinkStatus == .checking)

        await model.start()
        let running = model.engineRunning, engineError = model.engineError
        let status = model.phoneLinkStatus, wantsPush = model.wantsRemoteNotifications
        await model.stop()

        #expect(running)  // Mac-only operation works
        #expect(engineError == nil)
        #expect(received.values == [false])
        #expect(!wantsPush)
        guard case .off(let reason) = status else {
            Issue.record("expected off")
            return
        }
        #expect(reason.contains("entitlement"))
        #expect(calls.account == 0 && calls.transport == 0)
    }

    @Test func noICloudAccountFallsBackWithoutError() async {
        let calls = Calls()
        let received = Received()
        let model = model(calls.selector(entitled: true, account: .noAccount), socket: socketURL(), received: received)
        await model.start()
        let running = model.engineRunning, engineError = model.engineError, errorMessage = model.errorMessage
        let status = model.phoneLinkStatus, wantsPush = model.wantsRemoteNotifications
        await model.stop()

        #expect(running)
        #expect(engineError == nil)
        #expect(errorMessage == nil)
        #expect(received.values == [false])
        #expect(status == .off(reason: "not signed in to iCloud"))
        #expect(!wantsPush)
    }

    @Test func availableAccountBuildsTheEngineWithTheCloudKitTransport() async {
        let calls = Calls()
        let received = Received()
        let model = model(calls.selector(entitled: true, account: .available), socket: socketURL(), received: received)
        await model.start()
        let running = model.engineRunning, status = model.phoneLinkStatus, wantsPush = model.wantsRemoteNotifications
        await model.stop()

        #expect(running)
        #expect(received.values == [true])
        #expect(status == .on)
        #expect(wantsPush)
        #expect(calls.transport == 1)
    }

    @Test func startingTwiceChecksOnce() async {
        let calls = Calls()
        let received = Received()
        let model = model(calls.selector(entitled: true, account: .available), socket: socketURL(), received: received)
        await model.start()
        await model.start()
        await model.stop()
        #expect(calls.entitlement == 1)
        #expect(received.values.count == 1)
    }

    @Test func aPushThatIsNotBuddysIsIgnored() async {
        let calls = Calls()
        let model = model(calls.selector(entitled: true, account: .available), socket: socketURL(), received: Received())
        await model.start()
        let first = model.handleRemoteNotification(["aps": ["alert": "hi"]])
        let second = model.handleRemoteNotification([:])
        await model.stop()
        #expect(first == false)
        #expect(second == false)
    }

    @Test func decideBeforeStartIsRefusedNotACrash() async {
        let calls = Calls()
        let model = model(calls.selector(entitled: true, account: .available), socket: socketURL(), received: Received())
        #expect(await model.decide(UUID(), .deny) == false)
        await model.stop()  // stopping a model that never started is fine
    }

    @Test(.timeLimit(.minutes(1))) func aHungICloudCheckDoesNotKeepTheEngineFromStarting() async {
        let calls = Calls()
        let received = Received()
        var selector = calls.selector(entitled: true, account: .available)
        // Never answers and ignores cancellation, like a wedged iCloud daemon.
        selector.account = { await withUnsafeContinuation { (_: UnsafeContinuation<PhoneLinkAccount, Never>) in } }
        selector.accountTimeout = .milliseconds(150)
        let model = model(selector, socket: socketURL(), received: received)

        let started = ContinuousClock.now
        await model.start()
        let elapsed = ContinuousClock.now - started
        let running = model.engineRunning, engineError = model.engineError
        let status = model.phoneLinkStatus, wantsPush = model.wantsRemoteNotifications
        await model.stop()

        #expect(elapsed < .seconds(5))
        #expect(running)  // the hook socket is up: Claude Code hooks and the Mac card work
        #expect(engineError == nil)
        #expect(received.values == [false])
        #expect(!wantsPush)
        #expect(status == .off(reason: "iCloud check timed out; trying again"))
        #expect(calls.transport == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aLinkThatComesOnLaterReplacesTheMacOnlyEngine() async {
        let received = Received()
        let answers = Mutex<[PhoneLinkAccount]>([.timedOut, .temporarilyUnavailable])
        var selector = Calls().selector(entitled: true, account: .available)
        selector.account = { answers.withLock { $0.isEmpty ? .available : $0.removeFirst() } }
        selector.retryDelays = [.milliseconds(20)]
        let model = model(selector, socket: socketURL(), received: received)
        var registered = 0
        model.onPhoneLinkOn = { registered += 1 }

        await model.start()
        #expect(model.phoneLinkStatus == .off(reason: "iCloud check timed out; trying again"))
        #expect(model.engineRunning)
        let on = await waitFor { model.phoneLinkStatus == .on && model.engineRunning }
        let wantsPush = model.wantsRemoteNotifications
        await model.stop()

        #expect(on)
        #expect(received.values == [false, true])  // the second engine has the transport
        #expect(wantsPush)
        #expect(registered == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aLinkThatCannotComeOnIsNotRetried() async {
        let calls = Calls()
        var selector = calls.selector(entitled: true, account: .restricted)
        selector.retryDelays = [.milliseconds(10)]
        let model = model(selector, socket: socketURL(), received: Received())
        await model.start()
        try? await Task.sleep(for: .milliseconds(150))
        await model.stop()
        #expect(calls.account == 1)
    }

    @Test(.timeLimit(.minutes(1))) func stoppingEndsTheRetries() async {
        let calls = Calls()
        var selector = calls.selector(entitled: true, account: .timedOut)
        selector.retryDelays = [.milliseconds(10)]
        let model = model(selector, socket: socketURL(), received: Received())
        await model.start()
        await model.stop()
        let after = calls.account
        try? await Task.sleep(for: .milliseconds(150))
        #expect(calls.account == after)
    }

    /// A question waiting on the card when iCloud comes on is not killed by the engine swap: the link waits (and checks
    /// nothing) until no question is open, then comes on.
    @Test(.timeLimit(.minutes(1))) func aLinkThatComesOnWhileAQuestionWaitsWaitsForIt() async throws {
        let calls = Calls()
        let received = Received()
        let available = Flag()
        var selector = calls.selector(entitled: true, account: .available)
        selector.account = { available.value ? .available : .temporarilyUnavailable }
        selector.retryDelays = [.milliseconds(10)]
        let socket = socketURL()
        defer { try? FileManager.default.removeItem(at: socket) }
        let (model, store) = askingModel(selector, socket: socket, received: received)
        defer { store() }

        await model.start()
        #expect(model.phoneLinkStatus != .on)
        let client = Task.detached { askClient(socket: socket) }
        #expect(await waitFor { model.questions.count == 1 })
        available.value = true
        let checks = calls.account
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.questions.count == 1)
        #expect(received.values == [false])
        #expect(calls.account == checks)  // no iCloud check while the question waits

        let id = try #require(model.questions.first?.id)
        #expect(await model.answer(id, [.options(["Red"])]))
        #expect(await client.value?.contains("Red") == true)
        #expect(await waitFor { model.phoneLinkStatus == .on && model.engineRunning })
        #expect(received.values == [false, true])
        await model.stop()
    }

    /// The same when the question arrives while iCloud is being checked: the new link is dropped and tried again later.
    @Test(.timeLimit(.minutes(1))) func aQuestionArrivingDuringTheCheckKeepsTheEngine() async throws {
        let calls = Calls()
        let received = Received()
        let checking = Flag(), blocked = Flag(), proceed = Flag(), checked = Flag()
        var selector = calls.selector(entitled: true, account: .available)
        selector.account = {
            guard !checked.value else { return .available }
            guard checking.value else { return .temporarilyUnavailable }
            blocked.value = true
            while !proceed.value { try? await Task.sleep(for: .milliseconds(5)) }
            checked.value = true
            return .available
        }
        selector.retryDelays = [.milliseconds(10)]
        let socket = socketURL()
        defer { try? FileManager.default.removeItem(at: socket) }
        let (model, store) = askingModel(selector, socket: socket, received: received)
        defer { store() }

        await model.start()
        #expect(model.phoneLinkStatus != .on)
        checking.value = true  // the next check blocks until a question is open
        #expect(await waitFor { blocked.value })
        let client = Task.detached { askClient(socket: socket) }
        #expect(await waitFor { model.questions.count == 1 })
        proceed.value = true
        #expect(await waitFor { checked.value })
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.questions.count == 1)
        #expect(received.values == [false])

        let id = try #require(model.questions.first?.id)
        #expect(await model.answer(id, [.options(["Red"])]))
        _ = await client.value
        #expect(await waitFor { model.phoneLinkStatus == .on && model.engineRunning })
        #expect(received.values == [false, true])
        await model.stop()
    }

    /// A model whose engine has the model's question gate, with "Answer in Buddy" on and an unlocked screen, and its
    /// own defaults (the returned closure removes them).
    private func askingModel(
        _ selector: PhoneLinkSelector, socket: URL, received: Received
    ) -> (AppModel, () -> Void) {
        let name = "buddy-test-\(UUID().uuidString)"
        let model = AppModel(
            selector: selector,
            makeEngine: { transport, canAskInBuddy in
                received.append(transport != nil)
                return BuddyEngine(socketPath: socket, transport: transport, canAskInBuddy: canAskInBuddy)
            },
            paths: paths(), defaults: UserDefaults(suiteName: name)!,
            screen: ScreenPresence(center: NotificationCenter(), readLocked: { false }))
        return (model, { UserDefaults().removePersistentDomain(forName: name) })
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}
