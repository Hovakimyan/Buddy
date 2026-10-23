import Foundation

/// The decisions and file work behind "move Buddy to Applications". A downloaded app lives in Downloads, on a
/// mounted disk image or under an AppTranslocation path, where it can vanish; Applications is where it belongs.
/// Everything here is pure or takes its locations as parameters; the alert and the relaunch are in
/// `MoveToApplicationsUI.swift`.
enum MoveToApplications {
    struct Offer: Equatable {
        /// The running app (for an AppTranslocation run, the translocated path, which is readable).
        let source: URL
        /// Where the app really lives: `source`, or the original location of a translocated app. Shown to the person.
        let origin: URL
        /// Where the copy goes (`/Applications/<same name>.app`).
        let destination: URL
        /// An app by that name is already there; accepting replaces it.
        let replacesExisting: Bool
        /// Another Buddy (same bundle id) is running; accepting quits it first.
        var otherInstanceRunning = false
    }

    enum Skip: Equatable {
        /// Not running from an `.app` bundle (a `swift run` build, a test process).
        case notAnApp
        /// Any `BUDDY_*` override means a test setup; never move anything then.
        case overrideSet
        case underTests
        case alreadyInApplications
        /// Built by Xcode or xcodebuild: a developer's copy stays where it was built.
        case developmentBuild
    }

    enum Decision: Equatable {
        case skip(Skip)
        case offer(Offer)
    }

    /// Env vars that XCTest and Swift Testing set in a test process.
    private static let testEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

    /// True inside a test process.
    static func isUnderTests(environment: [String: String]) -> Bool {
        testEnvironmentKeys.contains { environment[$0] != nil } || NSClassFromString("XCTestCase") != nil
    }

    /// Whether to offer the move, checked in the order of the cases of `Skip`. `home` is the person's home
    /// directory (for `~/Applications`); `exists` says whether a path exists (to know if the copy would replace one).
    /// `originalLocation` maps an AppTranslocation path back to where the app really is (nil when it is not translocated),
    /// so an app that sits in /Applications but runs translocated is not offered the move again.
    static func decide(
        bundleURL: URL,
        environment: [String: String],
        isUnderTests: Bool,
        home: URL,
        otherInstanceRunning: Bool = false,
        originalLocation: (URL) -> URL? = { _ in nil },
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Decision {
        guard bundleURL.pathExtension == "app" else { return .skip(.notAnApp) }
        if LaunchEnvironment.isOverridden(environment) { return .skip(.overrideSet) }
        if isUnderTests { return .skip(.underTests) }
        let origin = originalLocation(bundleURL) ?? bundleURL
        let path = origin.resolvingSymlinksInPath().path
        let userApplications = home.resolvingSymlinksInPath().appendingPathComponent("Applications").path + "/"
        if path.hasPrefix("/Applications/") || path.hasPrefix(userApplications) { return .skip(.alreadyInApplications) }
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return .skip(.developmentBuild) }
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
        return .offer(Offer(
            source: bundleURL, origin: origin, destination: destination,
            replacesExisting: exists(destination.path), otherInstanceRunning: otherInstanceRunning))
    }

    /// Copies the app to `destination`: into a staging folder next to it first, then moved (or swapped, when
    /// replacing) into place, so a failed copy leaves any existing app untouched and nothing half-written
    /// under the final name.
    static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: source, to: staging)
            // The app is running, so Gatekeeper has already passed it. Left on the copy, the quarantine flag would make
            // macOS run it translocated again, and Buddy would offer to move itself on every launch.
            stripQuarantine(from: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static let quarantineAttribute = "com.apple.quarantine"

    /// Removes the quarantine attribute from `root` and everything inside it (symlinks themselves, not their targets).
    /// Best effort: a file without the attribute, or one that cannot be changed, is skipped.
    static func stripQuarantine(from root: URL) {
        removexattr(root.path, quarantineAttribute, XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(atPath: root.path)
        while let relative = items?.nextObject() as? String {
            removexattr(root.appendingPathComponent(relative).path, quarantineAttribute, XATTR_NOFOLLOW)
        }
    }

    /// The helper that opens the copy once this process has really gone. Not before: the copy would find
    /// this instance still holding the hook socket and fail to listen. If the process is still there after
    /// `maxWaitTicks` fifths of a second, it exits without opening anything (the copy is already in place and
    /// the person can open it). The pid, path, opener and tick count travel as arguments, never inside the
    /// script text.
    static func relaunchCommand(
        pid: Int32, copy: URL, opener: String = "/usr/bin/open", maxWaitTicks: Int = 100
    ) -> (executable: String, arguments: [String]) {
        let script = #"""
        i=0
        while kill -0 "$1" 2>/dev/null && [ "$i" -lt "$4" ]; do sleep 0.2; i=$((i+1)); done
        if kill -0 "$1" 2>/dev/null; then exit 1; fi
        exec "$3" "$2"
        """#
        return ("/bin/sh", ["-c", script, "buddy-relaunch", String(pid), copy.path, opener, String(maxWaitTicks)])
    }

    /// The alert text for an offer.
    static func prompt(for offer: Offer) -> (message: String, detail: String) {
        let folder = offer.origin.deletingLastPathComponent().path
        var detail = "Buddy is running from \(folder). Moved to Applications, it stays put when you empty Downloads or eject the disk image, and it can open at login."
        if offer.replacesExisting {
            detail += " This replaces the copy that is already in Applications."
        }
        if offer.otherInstanceRunning {
            detail += " Another Buddy is running; it will be quit first, and any approval waiting in it falls back to the terminal."
        }
        return ("Move Buddy to Applications?", detail)
    }
}
