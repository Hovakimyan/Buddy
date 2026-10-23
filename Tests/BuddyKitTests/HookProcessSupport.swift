import Foundation
import Testing

/// Runs the real `buddy-hook` executable the way Claude Code does: JSON on stdin, `BUDDY_SOCKET`
/// pointing at the socket under test and nothing else in the environment (so a test can never
/// reach the user's real Application Support directory).
enum HookProcess {
    struct Result: Sendable {
        let stdout: String
        let status: Int32
        let elapsed: TimeInterval
        /// True when the process did not exit within the bound and was killed by the harness.
        let killed: Bool
    }

    /// `buddy-hook` is built into the same products directory as the test bundle
    /// (`swift test` builds every product, so no extra build step is needed).
    static func binary() throws -> URL { try executable(named: "buddy-hook") }

    /// Any executable product (`buddy-hook`, `buddyctl`) next to the test bundle.
    static func executable(named name: String) throws -> URL {
        let bundleDirectory = Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent()
        let url = bundleDirectory.appendingPathComponent(name)
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "missing \(url.path)")
        return url
    }

    /// Short on purpose: `sockaddr_un` paths are limited to 104 bytes.
    static func tempSocketURL() -> URL {
        URL(fileURLWithPath: "/tmp/buddy-\(String(UUID().uuidString.prefix(8)).lowercased()).sock")
    }

    /// Starts the hook and returns at once; await the task for the outcome. `bound` is only a
    /// safety net (the process is killed and `killed` is set), never the expected duration.
    static func start(
        stdin: Data, socket: URL, arguments: [String] = [], bound: TimeInterval = 60
    ) -> Task<Result, Never> {
        Task {
            await run(stdin: stdin, socket: socket, arguments: arguments, bound: bound)
        }
    }

    static func run(
        stdin: Data, socket: URL, arguments: [String] = [], bound: TimeInterval = 60
    ) async -> Result {
        let process = Process()
        guard let executable = try? binary() else {
            return Result(stdout: "", status: -1, elapsed: 0, killed: false)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["BUDDY_SOCKET": socket.path]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        let start = Date()
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
                return
            }
            // Off the calling thread: a large payload blocks until the child has read it.
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + bound) {
                if process.isRunning { process.terminate() }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let out = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        return Result(
            stdout: String(decoding: out, as: UTF8.self),
            status: status,
            elapsed: elapsed,
            killed: elapsed >= bound && status != 0)
    }
}

private final class BundleLocator {}
