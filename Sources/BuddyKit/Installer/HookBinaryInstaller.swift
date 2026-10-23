#if os(macOS)
import Foundation

public enum HookBinaryInstallerError: Error, Equatable, LocalizedError {
    /// The `buddy-hook` to copy does not exist or is not executable.
    case sourceNotExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotExecutable(let path):
            return "buddy-hook is missing or not executable at \(path)"
        }
    }
}

/// Copies the `buddy-hook` executable into Buddy's support directory (`<support>/bin/buddy-hook`),
/// which is the path written into Claude Code's settings. Shared by `buddyctl` and the Mac app.
public enum HookBinaryInstaller {
    public static let executableName = "buddy-hook"
    /// The flag macOS puts on files that came from a download. Copied files keep it, and Gatekeeper then
    /// rejects (or stalls on) an ad-hoc signed `buddy-hook` every time Claude Code runs it.
    public static let quarantineAttribute = "com.apple.quarantine"

    /// Where `install(source:into:)` puts the binary for `supportDirectory`.
    public static func destination(in supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(executableName)
    }

    /// Copies `source` to `destination(in:)` with mode 0755 (also when replacing a binary that had other permissions) and returns that URL. The copy is staged
    /// next to the destination and moved into place, so a reader never sees a half-written file, and a
    /// failure leaves any existing binary untouched and no staging file behind. The support directory
    /// is created with mode 0700 and `bin` with 0755 when missing; a missing or non-executable
    /// `source` throws before anything is created. The copy never carries the quarantine flag: Buddy itself is
    /// already running, so Gatekeeper has passed it, and a flagged hook would silently stop every Claude Code event.
    @discardableResult
    public static func install(source: URL, into supportDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let source = source.resolvingSymlinksInPath()
        guard fm.isExecutableFile(atPath: source.path) else {
            throw HookBinaryInstallerError.sourceNotExecutable(source.path)
        }
        let destination = destination(in: supportDirectory)
        let binDirectory = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: supportDirectory.path) {
            try fm.createDirectory(
                at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: binDirectory.path) {
            try fm.createDirectory(
                at: binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let staging = binDirectory.appendingPathComponent(".\(executableName).tmp-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: staging)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            removeQuarantine(at: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return destination
    }

    /// True when `url` carries the quarantine flag.
    public static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the quarantine flag from `url` (the file itself, not a symlink's target). Missing flag: no-op.
    public static func removeQuarantine(at url: URL) {
        removexattr(url.path, quarantineAttribute, XATTR_NOFOLLOW)
    }
}

#endif
