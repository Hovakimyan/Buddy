import BuddyKit
import SwiftUI

/// Hook status plus the install/uninstall flows. Nothing is written until the user has seen the diff
/// and pressed Confirm.
struct SettingsView: View {
    static let windowID = "settings"

    private struct Review {
        let kind: HookReviewView.Kind
        let plan: InstallPlan
    }

    let model: AppModel
    @State private var review: Review?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
            HStack {
                Text("Built by Sergey Hovakimyan").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/Hovakimyan/Buddy")!)
            }

            if let review {
                HookReviewView(
                    kind: review.kind, plan: review.plan, onConfirm: { confirm(review) }, onCancel: { self.review = nil })
            } else {
                HStack {
                    Button("Install hooks…") { begin(.install) }
                    Button("Uninstall hooks…") { begin(.uninstall) }
                        .disabled(!model.hooksInstalled)
                }
            }

            if let message = model.resultMessage {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refresh = model.hookRefresh, let message = refresh.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(refresh.isFailure ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            questionsSection
            Divider()
            LaunchAtLoginControls(login: model.launchAtLogin)
            Divider()
            soundsSection
            Divider()

            if let notice = model.notListeningNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.phoneLinkStatus.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            review = nil
            model.refreshHooksInstalled()
            model.launchAtLogin.refresh()
        }
        .onDisappear { review = nil }
    }

    /// Whether Claude's questions wait for an answer on the island (and the phone). Off, the terminal asks them.
    private var questionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Answer Claude's questions in Buddy",
                isOn: Binding(get: { model.questionsEnabled }, set: { model.questionsEnabled = $0 }))
            Text("While Buddy waits for your answer, Claude Code shows no prompt in the terminal. Off, the terminal always asks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mute, volume and the user's sounds folder. The player keeps its own state (persisted, observable).
    private var soundsSection: some View {
        let player = SoundPlayer.shared
        return VStack(alignment: .leading, spacing: 6) {
            Text("Sounds").font(.headline)
            Toggle("Mute sounds", isOn: Binding(get: { player.isMuted }, set: { player.setMuted($0) }))
            HStack {
                Text("Volume")
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                    .disabled(player.isMuted)
            }
            HStack {
                Button("Open sounds folder") { player.openOverrideFolder() }
                Button("Reload sounds") { player.reload() }
            }
            Text(SoundPlayer.customCountText(player.customCount))
                .font(.callout)
            Text("Drop a file named like a sound (finish.wav, approval.m4a…) in the sounds folder to replace it, then Reload.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.hooksInstalled ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(model.hooksInstalled ? "Hooks installed" : "Hooks not installed")
                .font(.headline)
        }
    }

    private func begin(_ kind: HookReviewView.Kind) {
        do {
            let plan = try (kind == .install ? model.planInstall() : model.planUninstall())
            model.errorMessage = nil
            review = Review(kind: kind, plan: plan)
        } catch {
            model.report(error)
        }
    }

    private func confirm(_ review: Review) {
        do {
            switch review.kind {
            case .install: try model.applyInstall(review.plan)
            case .uninstall: try model.applyUninstall(review.plan)
            }
        } catch {
            model.report(error)
        }
        self.review = nil
    }
}

/// The diff of a planned hook install or uninstall, with Confirm and Cancel. Settings shows it inline, the setup
/// window in a sheet; either way nothing is written before Confirm.
struct HookReviewView: View {
    enum Kind {
        case install, uninstall

        var title: String { self == .install ? "Install hooks" : "Uninstall hooks" }
    }

    let kind: Kind
    let plan: InstallPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.changed {
                Text("\(kind.title): these changes will be written to your Claude settings. A backup of the existing file is kept next to it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(plan.diff)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            } else if kind == .install {
                Text("The settings file already has Buddy's hooks. Confirm to refresh the installed hook binary.")
                    .font(.callout)
            } else {
                Text("There is nothing to remove.").font(.callout)
            }
            HStack {
                Button("Confirm", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(kind == .uninstall && !plan.changed)
                Button("Cancel", action: onCancel)
            }
        }
    }
}

/// The login-item toggle with the status macOS reports (it can change in System Settings behind our back). In
/// Settings and in the setup window.
struct LaunchAtLoginControls: View {
    let login: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Open Buddy at login",
                isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
            Text(login.status.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if login.status == .requiresApproval {
                Button("Open Login Items Settings…") { SystemLoginItem.openSystemSettings() }
            }
            if let error = login.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
