import Foundation
import Testing

// SAFETY: only the fake login item is used here. Nothing in this file may build `SystemLoginItem`, which would
// register (or read) the real login item of whoever runs the tests.

@MainActor
private final class FakeLoginItem: LoginItemService {
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    var status: LoginItemStatus
    var failWith: Error?
    /// What macOS says after a successful `register()`; `.enabled` unless the test wants an approval prompt.
    var statusAfterRegister: LoginItemStatus = .enabled
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(_ status: LoginItemStatus) { self.status = status }

    func register() throws {
        registerCalls += 1
        if let failWith { throw failWith }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failWith { throw failWith }
        status = .notRegistered
    }
}

@MainActor
@Suite struct LaunchAtLoginTests {
    @Test func startsWithTheRealStatus() {
        #expect(LaunchAtLogin(service: FakeLoginItem(.enabled)).isOn)
        #expect(LaunchAtLogin(service: FakeLoginItem(.notRegistered)).isOn == false)
        #expect(LaunchAtLogin(service: FakeLoginItem(.requiresApproval)).isOn)
        #expect(LaunchAtLogin(service: FakeLoginItem(.notFound)).isOn == false)
    }

    @Test func turningItOnRegisters() {
        let fake = FakeLoginItem(.notRegistered)
        let login = LaunchAtLogin(service: fake)
        login.set(true)
        #expect(fake.registerCalls == 1)
        #expect(login.status == .enabled)
        #expect(login.errorMessage == nil)
    }

    @Test func turningItOffUnregisters() {
        let fake = FakeLoginItem(.enabled)
        let login = LaunchAtLogin(service: fake)
        login.set(false)
        #expect(fake.unregisterCalls == 1)
        #expect(login.status == .notRegistered)
        #expect(login.isOn == false)
    }

    @Test func approvalPendingShowsTheRealStatusNotEnabled() {
        let fake = FakeLoginItem(.notRegistered)
        fake.statusAfterRegister = .requiresApproval
        let login = LaunchAtLogin(service: fake)
        login.set(true)
        #expect(login.status == .requiresApproval)
        #expect(login.isOn)
        #expect(login.status.text.contains("System Settings"))
    }

    @Test func aFailureShowsItsTextAndKeepsTheRealStatus() {
        let fake = FakeLoginItem(.notRegistered)
        fake.failWith = FakeLoginItem.Refused()
        let login = LaunchAtLogin(service: fake)
        login.set(true)
        #expect(login.errorMessage == "Could not turn on launch at login: Operation not permitted")
        #expect(login.status == .notRegistered)
        #expect(login.isOn == false)
        // The next success clears the error.
        fake.failWith = nil
        login.set(true)
        #expect(login.errorMessage == nil)
        #expect(login.status == .enabled)
    }

    @Test func aFailedUnregisterSaysTurnOff() {
        let fake = FakeLoginItem(.enabled)
        fake.failWith = FakeLoginItem.Refused()
        let login = LaunchAtLogin(service: fake)
        login.set(false)
        #expect(login.errorMessage?.hasPrefix("Could not turn off launch at login") == true)
        #expect(login.status == .enabled)
    }

    @Test func anAlreadyMatchingStateIsNotRegisteredAgain() {
        let enabled = FakeLoginItem(.enabled)
        LaunchAtLogin(service: enabled).set(true)
        #expect(enabled.registerCalls == 0)
        let off = FakeLoginItem(.notRegistered)
        LaunchAtLogin(service: off).set(false)
        #expect(off.unregisterCalls == 0)
    }

    @Test func refreshPicksUpAChangeMadeInSystemSettings() {
        let fake = FakeLoginItem(.requiresApproval)
        let login = LaunchAtLogin(service: fake)
        fake.status = .enabled
        #expect(login.status == .requiresApproval)
        login.refresh()
        #expect(login.status == .enabled)
    }

    @Test func everyStatusHasADistinctSentence() {
        let all: [LoginItemStatus] = [.enabled, .requiresApproval, .notRegistered, .notFound]
        #expect(Set(all.map(\.text)).count == 4)
        #expect(LoginItemStatus.notFound.text.contains("Applications"))
    }

    @Test func theModelsTestInitializerNeverTouchesARealLoginItem() {
        // The default is the inert one: it reports "not found" and refuses to register.
        let login = LaunchAtLogin(service: NoLoginItem())
        #expect(login.status == .notFound)
        login.set(true)
        #expect(login.errorMessage?.contains("not available") == true)
    }
}
