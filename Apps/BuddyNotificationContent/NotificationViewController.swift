import BuddyKit
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// What a long-press on a Buddy notification shows: Buddy, the project, and the whole command or question. For a
/// question with one choice to make, each option becomes a button; tapping one answers without opening Buddy (iOS
/// asks to unlock the iPhone first). The text comes from the notification service (`NotificationDetail`).
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<DetailView>?

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let detail = NotificationDetail(userInfo: content.userInfo)
        let detailView = DetailView(detail: detail, fallbackTitle: content.title, fallbackBody: content.body)
        if let host {
            host.rootView = detailView
        } else {
            let host = UIHostingController(rootView: detailView)
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear
            self.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            ])
            host.didMove(toParent: self)
            self.host = host
        }
        preferredContentSize = host?.view.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height)) ?? preferredContentSize

        // One button per option, only for a single question with one choice. The app checks it again when the
        // tap arrives (against the question fetched from the cloud) before anything is sent.
        if let detail, detail.kind == .question, detail.canAnswerHere {
            extensionContext?.notificationActions = detail.options.enumerated().map { index, label in
                UNNotificationAction(
                    identifier: QuestionAnswerAction.identifier(option: index), title: label,
                    options: [.authenticationRequired])
            }
        }
    }
}

private struct DetailView: View {
    let detail: NotificationDetail?
    let fallbackTitle: String
    let fallbackBody: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BuddyFace(state: detail?.kind == .question ? .question : .approval, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading).font(.headline).lineLimit(1)
                    if let project = detail?.project {
                        Text(project).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if let detail, detail.kind == .approval, let summary = detail.summary {
                Text(summary)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text(detail.canAllowHere ? "Allow needs your iPhone unlocked." : "Open Buddy to allow this one.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let detail, detail.kind == .question {
                if let text = detail.text { Text(text).font(.body.weight(.semibold)) }
                if detail.canAnswerHere {
                    Text("Pick an answer below. It needs your iPhone unlocked.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Open Buddy to answer.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(fallbackBody).font(.body)
            }
        }
        .padding(16)
    }

    private var heading: String {
        switch detail?.kind {
        case .approval?: detail?.tool ?? fallbackTitle
        case .question?: detail?.header ?? "Claude is asking"
        case nil: fallbackTitle
        }
    }
}
