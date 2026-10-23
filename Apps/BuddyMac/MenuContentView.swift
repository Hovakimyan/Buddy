import BuddyKit
import SwiftUI

extension SessionState {
    var color: Color {
        switch self {
        case .idle: .gray
        case .working: .blue
        case .waiting: .orange
        case .finished: .green
        case .error: .red
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .finished: "Finished"
        case .error: "Error"
        }
    }
}

/// The menu-bar icon, with the number of approvals waiting for a decision.
struct MenuBarLabel: View {
    let model: AppModel
    let launch: LaunchCoordinator
    let island: IslandWindowController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pawprint")
            if !model.pending.isEmpty {
                Text("\(model.pending.count)")
            }
        }
        // The label exists from launch (the popover's content does not), so this runs once at startup.
        .task {
            // The island is AppKit and has no `openWindow` of its own: its settings button borrows this one.
            island.openSettings = {
                openWindow(id: SettingsView.windowID)
                NSApp.activate()
            }
            await launch.run(openSetup: openSetup)
        }
        // Hooks that turn outdated while Buddy runs (the settings file was re-read) bring the setup window back.
        .onChange(of: model.hookStatus) { _, status in
            if status == .outdated { openSetup() }
        }
    }

    private func openSetup() {
        openWindow(id: SetupWindow.windowID)
        NSApp.activate()
    }
}

/// The menu-bar popover: live sessions, the pending-approval badge, Demo, Setup steps, Open Settings and Quit.
/// Plain on purpose: the island is where sessions and cards are shown in full.
struct MenuContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Buddy").font(.headline)
                Spacer()
                if !model.pending.isEmpty {
                    Text("\(model.pending.count) pending")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                        .foregroundStyle(.white)
                        .accessibilityLabel("\(model.pending.count) approvals pending")
                }
            }

            if let notice = model.notListeningNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.phoneLinkStatus.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if model.sessions.isEmpty {
                Text("No Claude Code sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sessions) { session in
                    SessionRow(session: session)
                }
            }

            Divider()

            Button(Self.demoTitle(running: model.isDemoRunning)) {
                if model.isDemoRunning { model.stopDemo() } else { model.startDemo() }
            }
            .buttonStyle(.plain)
            .disabled(!model.isDemoRunning && !model.canStartDemo)
            Button {
                openWindow(id: SetupWindow.windowID)
                NSApp.activate()
            } label: {
                HStack(spacing: 6) {
                    Text(SetupSteps.menuTitle)
                    // A dot while a required setup step is still to do.
                    if model.setupNeedsAttention {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.setupNeedsAttention ? "\(SetupSteps.menuTitle), steps left to do" : SetupSteps.menuTitle)
            Button("Open Settings") {
                openWindow(id: SettingsView.windowID)
                NSApp.activate()
            }
            .buttonStyle(.plain)
            Button("Quit Buddy") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }

    /// The demo item: it plays the scripted session on the island, or ends the one playing.
    static func demoTitle(running: Bool) -> String { running ? "Stop demo" : "Demo" }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.state.color)
                .frame(width: 9, height: 9)
                .accessibilityLabel(session.state.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).lineLimit(1)
                if let tool = session.lastTool {
                    Text(tool).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
