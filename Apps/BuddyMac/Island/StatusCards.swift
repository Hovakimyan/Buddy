import SwiftUI

/// A card that tells rather than asks: how a session ended, the dizzy spell, or what became of a card answered
/// somewhere else.
enum StatusCardKind: Equatable, Hashable, Sendable {
    case error(details: String?)
    case finished(lastLine: String?)
    /// Shown while the character is dizzy (about 3 s).
    case dizzy
    /// A card that was answered elsewhere; `where` reads after "in", like "the terminal".
    case answered(where: String)
    /// A card that timed out here: the terminal still asks.
    case stillWaiting

    var title: String {
        switch self {
        case .error: "This session stopped with an error."
        case .finished: "Claude is done"
        case .dizzy: "Whoa, too many boops!"
        case .answered(let place): "Answered in \(place)."
        case .stillWaiting: "Still waiting in the terminal."
        }
    }

    var detail: String? {
        switch self {
        case .error(let details): details
        case .finished(let lastLine): lastLine
        case .dizzy, .answered, .stillWaiting: nil
        }
    }

    /// Error and finished stay until OK; the others go by themselves.
    var hasOK: Bool {
        switch self {
        case .error, .finished: true
        case .dizzy, .answered, .stillWaiting: false
        }
    }

    var symbol: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .finished: "checkmark.circle.fill"
        case .dizzy: "tornado"
        case .answered: "checkmark.bubble.fill"
        case .stillWaiting: "terminal.fill"
        }
    }
}

/// The card for a `StatusCardKind`, washed in the character's accent.
struct StatusCardView: View {
    let kind: StatusCardKind
    let accent: Color
    let onOK: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let detail = kind.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if kind.hasOK {
                Button(action: onOK) {
                    Text("OK")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 56, height: 26)
                        .background(Capsule().fill(accent.opacity(0.85)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(IslandLayout.cardPadding)
        .frame(height: IslandLayout.statusCardHeight)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.22), Color.white.opacity(0.06)], startPoint: .leading,
                    endPoint: .trailing)))
        .accessibilityElement(children: .combine)
    }
}
