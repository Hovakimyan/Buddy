import BuddyKit
import Foundation
import Testing

// SAFETY: decisions take fake locations and an injected environment; file work runs in temp directories only.
// Nothing here may touch the real /Applications, show an alert, spawn the relaunch helper or quit anything.

private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

private func decide(
    _ path: String, environment: [String: String] = [:], underTests: Bool = false, existing: Set<String> = [],
    otherRunning: Bool = false, originals: [String: String] = [:]
) -> MoveToApplications.Decision {
    MoveToApplications.decide(
        bundleURL: URL(fileURLWithPath: path, isDirectory: true), environment: environment,
        isUnderTests: underTests, home: home, otherInstanceRunning: otherRunning,
        originalLocation: { originals[$0.path].map { URL(fileURLWithPath: $0, isDirectory: true) } },
        exists: { existing.contains($0) })
}

@Suite struct MoveToApplicationsDecisionTests {
    @Test(arguments: [
        "/Users/tester/Downloads/BuddyMac.app",
        "/Volumes/Buddy 0.1.0/BuddyMac.app",
        "/private/var/folders/xy/T/AppTranslocation/8A1B2C3D-0000-0000-0000-000000000000/d/BuddyMac.app",
        "/Users/tester/Desktop/BuddyMac.app",
    ])
    func offersWhenRunningFromOutsideApplications(path: String) {
        #expect(decide(path) == .offer(.init(
            source: URL(fileURLWithPath: path, isDirectory: true),
            origin: URL(fileURLWithPath: path, isDirectory: true),
            destination: URL(fileURLWithPath: "/Applications/BuddyMac.app", isDirectory: true),
            replacesExisting: false)))
    }

    @Test(arguments: [
        "/Applications/BuddyMac.app",
        "/Applications/Utilities/BuddyMac.app",
        "/Users/tester/Applications/BuddyMac.app",
    ])
    func staysQuietInApplications(path: String) {
        #expect(decide(path) == .skip(.alreadyInApplications))
    }

    @Test func aLookAlikeFolderIsNotApplications() {
        // "/Applications Old/..." and another user's Applications folder are not the install locations.
        #expect(decide("/Applications Old/BuddyMac.app") != .skip(.alreadyInApplications))
        #expect(decide("/Users/other/Applications/BuddyMac.app") != .skip(.alreadyInApplications))
    }

    @Test func anExistingCopyMeansTheMoveReplacesIt() {
        let decision = decide("/Users/tester/Downloads/BuddyMac.app", existing: ["/Applications/BuddyMac.app"])
        guard case .offer(let offer) = decision else {
            Issue.record("expected an offer, got \(decision)")
            return
        }
        #expect(offer.replacesExisting)
        #expect(MoveToApplications.prompt(for: offer).detail.contains("replaces"))
    }

    private static let translocated = "/private/var/folders/xy/T/AppTranslocation/8A1B2C3D/d/BuddyMac.app"

    @Test func aTranslocatedAppThatLivesInApplicationsIsNotOfferedAgain() {
        #expect(decide(Self.translocated, originals: [Self.translocated: "/Applications/BuddyMac.app"])
            == .skip(.alreadyInApplications))
        #expect(decide(Self.translocated, originals: [Self.translocated: "/Users/tester/Applications/BuddyMac.app"])
            == .skip(.alreadyInApplications))
    }

    @Test func aTranslocatedDownloadIsOfferedAndShowsItsRealFolder() {
        let decision = decide(Self.translocated, originals: [Self.translocated: "/Users/tester/Downloads/BuddyMac.app"])
        guard case .offer(let offer) = decision else {
            Issue.record("expected an offer, got \(decision)")
            return
        }
        // It copies from the readable translocated path and tells the person the real folder.
        #expect(offer.source.path == Self.translocated)
        #expect(offer.origin.path == "/Users/tester/Downloads/BuddyMac.app")
        #expect(MoveToApplications.prompt(for: offer).detail.contains("/Users/tester/Downloads"))
        #expect(!MoveToApplications.prompt(for: offer).detail.contains("AppTranslocation"))
    }

    @Test func anotherRunningBuddyIsPartOfTheOfferAndThePrompt() {
        guard case .offer(let offer) = decide("/Users/tester/Downloads/BuddyMac.app", otherRunning: true) else {
            Issue.record("expected an offer")
            return
        }
        #expect(offer.otherInstanceRunning)
        let detail = MoveToApplications.prompt(for: offer).detail
        #expect(detail.contains("will be quit"))
        #expect(detail.contains("terminal"))
        guard case .offer(let alone) = decide("/Users/tester/Downloads/BuddyMac.app") else {
            Issue.record("expected an offer")
            return
        }
        #expect(!MoveToApplications.prompt(for: alone).detail.contains("will be quit"))
    }

    @Test func theDestinationKeepsTheAppsName() {
        guard case .offer(let offer) = decide("/Volumes/Buddy/Buddy.app") else {
            Issue.record("expected an offer")
            return
        }
        #expect(offer.destination.path == "/Applications/Buddy.app")
    }

    @Test(arguments: ["BUDDY_SOCKET", "BUDDY_SETTINGS", "BUDDY_HOME", "BUDDY_ANYTHING", "BUDDY_SNAPSHOT_DIR"])
    func anyBuddyOverrideSkipsTheOffer(key: String) {
        #expect(decide("/Users/tester/Downloads/BuddyMac.app", environment: [key: "/tmp/x"]) == .skip(.overrideSet))
        // Even an empty value counts: it still means someone is setting up a test run.
        #expect(decide("/Users/tester/Downloads/BuddyMac.app", environment: [key: ""]) == .skip(.overrideSet))
    }

    @Test func unrelatedEnvironmentDoesNotSkip() {
        let environment = ["HOME": "/Users/tester", "BUDDYISH": "1", "MY_BUDDY_X": "1"]
        if case .skip = decide("/Users/tester/Downloads/BuddyMac.app", environment: environment) {
            Issue.record("an unrelated environment must not skip the offer")
        }
    }

    @Test func underTestsSkips() {
        #expect(decide("/Users/tester/Downloads/BuddyMac.app", underTests: true) == .skip(.underTests))
    }

    @Test func notAnAppBundleSkips() {
        #expect(decide("/Users/tester/.build/debug/BuddyTests.xctest") == .skip(.notAnApp))
        #expect(decide("/usr/local/bin/buddy") == .skip(.notAnApp))
    }

    @Test func aDevelopersBuildStaysWhereItWasBuilt() {
        #expect(decide("/Users/tester/Library/Developer/Xcode/DerivedData/Buddy-abc/Build/Products/Debug/BuddyMac.app")
            == .skip(.developmentBuild))
        #expect(decide("/Users/tester/Projects/buddy/Apps/build/Build/Products/Release/BuddyMac.app")
            == .skip(.developmentBuild))
    }

    @Test func theTestProcessItselfIsRecognised() {
        // This very process is a test: the real detector must say so, with the real environment.
        #expect(MoveToApplications.isUnderTests(environment: ProcessInfo.processInfo.environment))
        #expect(MoveToApplications.isUnderTests(environment: ["XCTestConfigurationFilePath": "/x"]))
    }

    @Test func theRealTranslocationLookupSaysNilForAnOrdinaryPath() {
        // Read-only: asks macOS about a normal path. Also proves the run-time symbol lookup does not crash.
        #expect(Translocation.originalLocation(of: FileManager.default.temporaryDirectory) == nil)
        #expect(Translocation.originalLocation(of: URL(fileURLWithPath: "/Applications/Nonexistent.app")) == nil)
    }

    @Test func theRelaunchHelperGetsItsInputsAsArgumentsNotScriptText() {
        let copy = URL(fileURLWithPath: "/Applications/My \"Buddy\"; rm -rf ~.app")
        let command = MoveToApplications.relaunchCommand(pid: 4242, copy: copy)
        #expect(command.executable == "/bin/sh")
        #expect(Array(command.arguments.suffix(4)) == ["4242", copy.path, "/usr/bin/open", "100"])
        let script = command.arguments[1]
        #expect(!script.contains("rm -rf"))
        #expect(!script.contains("4242"))
    }
}

/// Runs the real relaunch helper under /bin/sh against short-lived processes, with a stub in place of `open`.
@Suite struct RelaunchHelperTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A stub opener: records its argument exactly (and whether the watched pid was still alive) into `out`.
    private func makeOpener(in root: URL, watching pid: Int32?) throws -> (opener: String, out: URL) {
        let out = root.appendingPathComponent("opened.txt")
        let opener = root.appendingPathComponent("fake-open.sh")
        let alive = pid.map { "if kill -0 \($0) 2>/dev/null; then printf 'ALIVE' > '\(root.path)/state.txt'; else printf 'GONE' > '\(root.path)/state.txt'; fi\n" } ?? ""
        try Data(("#!/bin/sh\n" + alive + "printf '%s' \"$1\" > '\(out.path)'\n").utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        return (opener.path, out)
    }

    /// Starts `sleep seconds` as a direct child: Foundation reaps it the moment it exits, so `kill -0` stops
    /// succeeding then (a detached orphan can linger as a zombie for a long time).
    private func startSleeper(seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [String(seconds)]
        try process.run()
        return process
    }

    private func runHelper(pid: Int32, copy: URL, opener: String, ticks: Int) throws -> Int32 {
        let command = MoveToApplications.relaunchCommand(pid: pid, copy: copy, opener: opener, maxWaitTicks: ticks)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func waitsForTheProcessToExitThenOpensTheCopy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sleeper = try startSleeper(seconds: 1)
        let pid = sleeper.processIdentifier
        let stub = try makeOpener(in: root, watching: pid)
        let copy = URL(fileURLWithPath: "/Applications/BuddyMac.app")
        let started = Date()

        let status = try runHelper(pid: pid, copy: copy, opener: stub.opener, ticks: 100)

        #expect(status == 0)
        #expect(Date().timeIntervalSince(started) > 0.5)  // it really waited for the sleeper
        #expect(try String(contentsOf: stub.out, encoding: .utf8) == "/Applications/BuddyMac.app")
        #expect(try String(contentsOf: root.appendingPathComponent("state.txt"), encoding: .utf8) == "GONE")
    }

    @Test func aProcessThatNeverExitsMeansNothingIsOpened() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sleeper = try startSleeper(seconds: 30)
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        let stub = try makeOpener(in: root, watching: nil)

        let status = try runHelper(pid: pid, copy: URL(fileURLWithPath: "/Applications/BuddyMac.app"), opener: stub.opener, ticks: 3)

        #expect(status != 0)
        #expect(!FileManager.default.fileExists(atPath: stub.out.path))
    }

    @Test func awkwardPathsStayDataAndArriveIntact() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A pid that has already exited: start and finish a process first.
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let marker = root.appendingPathComponent("injected")
        let stub = try makeOpener(in: root, watching: nil)
        let path = "/Applications/It's \"Buddy\" $HOME `touch \(marker.path)` $(touch \(marker.path)); a b\nline2.app"

        let status = try runHelper(pid: finished.processIdentifier, copy: URL(fileURLWithPath: path), opener: stub.opener, ticks: 100)

        #expect(status == 0)
        #expect(try String(contentsOf: stub.out, encoding: .utf8) == path)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

@Suite struct MoveToApplicationsCopyTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A stand-in app bundle: a folder with a couple of files.
    private func makeApp(at url: URL, version: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("binary \(version)".utf8).write(to: macOS.appendingPathComponent("BuddyMac"))
        try Data("info \(version)".utf8).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func version(of app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func copiesTheWholeBundleAndLeavesTheOriginal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Downloads/BuddyMac.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/BuddyMac.app", isDirectory: true)
        try makeApp(at: source, version: "1")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        try MoveToApplications.copy(from: source, to: destination)

        #expect(version(of: destination) == "info 1")
        #expect(try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/BuddyMac")) == Data("binary 1".utf8))
        #expect(version(of: source) == "info 1")
        // Nothing else is left in the destination folder (no staging copy).
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["BuddyMac.app"])
    }

    private func quarantine(_ url: URL) -> String? {
        let name = MoveToApplications.quarantineAttribute
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        return read >= 0 ? String(decoding: buffer.prefix(read), as: UTF8.self) : nil
    }

    private func setQuarantine(_ url: URL, _ value: String = "0083;5f000000;Safari;") {
        _ = value.withCString { setxattr(url.path, MoveToApplications.quarantineAttribute, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    @Test func theCopyLosesTheQuarantineFlagEverywhereAndTheOriginalKeepsIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Downloads/BuddyMac.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/BuddyMac.app", isDirectory: true)
        try makeApp(at: source, version: "1")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let inner = [
            source, source.appendingPathComponent("Contents"), source.appendingPathComponent("Contents/Info.plist"),
            source.appendingPathComponent("Contents/MacOS/BuddyMac"),
        ]
        for url in inner { setQuarantine(url) }
        // Another attribute must survive the copy.
        _ = "keep".withCString { setxattr(source.appendingPathComponent("Contents/Info.plist").path, "com.buddy.test", $0, 4, 0, 0) }

        try MoveToApplications.copy(from: source, to: destination)

        for url in inner { #expect(quarantine(url) != nil, "the original must keep its flag: \(url.lastPathComponent)") }
        for relative in ["", "Contents", "Contents/Info.plist", "Contents/MacOS/BuddyMac"] {
            let copy = relative.isEmpty ? destination : destination.appendingPathComponent(relative)
            #expect(quarantine(copy) == nil, "the copy must lose its flag: \(relative)")
        }
        #expect(getxattr(destination.appendingPathComponent("Contents/Info.plist").path, "com.buddy.test", nil, 0, 0, 0) == 4)
    }

    @Test func stripQuarantineLeavesFilesWithoutTheFlagAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("BuddyMac.app", isDirectory: true)
        try makeApp(at: app, version: "1")
        MoveToApplications.stripQuarantine(from: app)  // nothing to remove, nothing breaks
        #expect(version(of: app) == "info 1")
    }

    @Test func replacesAnExistingCopy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Downloads/BuddyMac.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/BuddyMac.app", isDirectory: true)
        try makeApp(at: source, version: "2")
        try makeApp(at: destination, version: "1")

        try MoveToApplications.copy(from: source, to: destination)

        #expect(version(of: destination) == "info 2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["BuddyMac.app"])
    }

    @Test func aFailedCopyLeavesTheExistingAppAndNoStagingBehind() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Downloads/Gone.app", isDirectory: true)
        let destination = root.appendingPathComponent("Applications/BuddyMac.app", isDirectory: true)
        try makeApp(at: destination, version: "1")

        #expect(throws: (any Error).self) { try MoveToApplications.copy(from: missing, to: destination) }

        #expect(version(of: destination) == "info 1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["BuddyMac.app"])
    }

    @Test func aMissingApplicationsFolderIsAnErrorNotACreatedFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("BuddyMac.app", isDirectory: true)
        try makeApp(at: source, version: "1")
        let destination = root.appendingPathComponent("nope/BuddyMac.app", isDirectory: true)
        #expect(throws: (any Error).self) { try MoveToApplications.copy(from: source, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("nope").path))
    }
}
