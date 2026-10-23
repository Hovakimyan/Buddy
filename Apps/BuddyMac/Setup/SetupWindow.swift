import BuddyKit
import SwiftUI

/// The setup window: what to do after installing Buddy, one step at a time, each with a check once it is done. It
/// replaces the old Settings welcome. Opens on the first launch, whenever the hooks are outdated, and from the menu's
/// "Setup steps…". Every action reuses an existing path: the move alert, the install diff and Confirm, the login
/// item, the demo.
struct SetupWindow: View {
    static let windowID = "setup"

    let model: AppModel
    let launch: LaunchCoordinator
    /// The install plan under review in the sheet (nothing is written before its Confirm).
    @State private var review: InstallPlan?
    /// When Block greets the first session seen in this window (or the one already seen, when the window opens).
    @State private var greetedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let steps = model.setupSteps
        let current = steps.first { $0.id.isRequired && !$0.done }?.id
        // Scrolls when the screen is shorter than the steps (a 13" display with a two-line title and an error showing).
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Buddy").font(.title2.bold())
                    Text("Each step gets a check mark when it is done.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    row(step, number: index + 1, isCurrent: step.id == current)
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 520)
        .frame(minHeight: 320, idealHeight: 720)
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if let review {
                HookReviewView(
                    kind: .install, plan: review, onConfirm: { confirmInstall(review) }, onCancel: { self.review = nil })
                    .padding(20)
                    .frame(width: 480)
            }
        }
        .onAppear {
            review = nil
            model.refreshHooksInstalled()
            model.launchAtLogin.refresh()
            model.setupWindowDidAppear()
            if model.seenEventProject != nil { greetedAt = Date() }
        }
        .onChange(of: model.seenEventProject) { _, project in
            if project != nil { greetedAt = Date() }
        }
    }

    // MARK: Rows

    private func row(_ step: SetupStep, number: Int, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            marker(done: step.done, number: number)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if step.id == .check { checkStatus(step) } else if !step.body.isEmpty { bodyText(step) }
                actions(for: step)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(step.title), \(step.done ? "done" : "to do")")
    }

    /// A green check when done, the step's number while it is still to do.
    private func marker(done: Bool, number: Int) -> some View {
        ZStack {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                Text("\(number)").font(.callout.bold()).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private func bodyText(_ step: SetupStep) -> some View {
        Text(Self.displayed(step))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Step 4: a spinner while waiting for the first hook event, then Block's greeting and the project.
    @ViewBuilder
    private func checkStatus(_ step: SetupStep) -> some View {
        HStack(spacing: 10) {
            if step.done {
                let start = greetedAt ?? Date()
                CharacterRegistry.all[0].view(CharacterInput(
                    state: .idle, emote: nil, emoteStartedAt: nil, stateStartedAt: start, hovering: false,
                    boopedAt: nil, greetingStartedAt: greetedAt, look: .zero, size: 36, reduceMotion: reduceMotion))
                    .frame(width: 36, height: 36)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            bodyText(step)
        }
    }

    @ViewBuilder
    private func actions(for step: SetupStep) -> some View {
        switch step.id {
        case .applications:
            if !step.done {
                Button("Move to Applications") { Task { await launch.moveToApplications() } }
            }
        case .connect:
            if !step.done {
                Button("Review and install") { beginInstall() }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .check:
            // Disabled while the demo plays and while a real card waits (the island must show that one).
            Button("Try the demo") { model.startDemo() }
                .disabled(model.isDemoRunning || !model.canStartDemo)
        case .openAtLogin:
            LaunchAtLoginControls(login: model.launchAtLogin)
        case .openSessions, .iPhone:
            EmptyView()
        }
    }

    // MARK: Install

    private func beginInstall() {
        do {
            let plan = try model.planInstall()
            model.errorMessage = nil
            review = plan
        } catch {
            model.report(error)
        }
    }

    private func confirmInstall(_ plan: InstallPlan) {
        do {
            try model.applyInstall(plan)
        } catch {
            model.report(error)
        }
        review = nil
    }

    /// A step's body as shown. Step 4 names the project, a folder name that must not be read as Markdown, so it is
    /// plain; the other bodies are fixed text with inline code.
    nonisolated static func displayed(_ step: SetupStep) -> AttributedString {
        step.id == .check ? AttributedString(step.body) : rendered(step.body)
    }

    /// A step body with its backticked parts (paths, commands) as inline code.
    nonisolated static func rendered(_ body: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }
}
