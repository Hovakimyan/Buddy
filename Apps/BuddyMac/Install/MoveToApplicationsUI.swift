import AppKit
import Foundation

/// The alerts for the move offer. Thin AppKit glue: the wording is `MoveToApplications.prompt(for:)`.
@MainActor
struct AlertMovePresenter: MovePresenting {
    func confirmMove(_ offer: MoveToApplications.Offer) -> Bool {
        let text = MoveToApplications.prompt(for: offer)
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showMoveFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not move Buddy"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}

/// Opens the copy after this process has quit, then quits it.
enum AppRelauncher {
    @MainActor
    static func relaunchAndQuit(_ copy: URL) throws {
        let command = MoveToApplications.relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier, copy: copy)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try process.run()
        // Quitting goes through applicationShouldTerminate, which stops the engine and removes the socket.
        NSApp.terminate(nil)
    }
}
