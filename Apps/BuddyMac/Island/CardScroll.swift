import SwiftUI

extension EnvironmentValues {
    /// Whether the question and plan cards may use views AppKit backs: the scroll view and the text field. Off only
    /// where those cannot be made, drawing the cards with `ImageRenderer` outside an app: what does not fit is cut at
    /// the bottom instead of scrolling, and the field is drawn as its text.
    @Entry var cardsMakeAppKitViews = true
}

/// The part of a card that scrolls when the card is shorter than it (see `cardsMakeAppKitViews`).
struct CardScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.cardsMakeAppKitViews) private var scrolls

    var body: some View {
        if scrolls {
            ScrollView(.vertical) { content }
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
    }
}
