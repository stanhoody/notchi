import AppKit
import SwiftUI

/// An NSHostingView that accepts the first mouse click. Notchi's notch panel is a non-key,
/// nonactivating panel of an .accessory app, so without this AppKit treats clicks as
/// "first-mouse" activation events and drops them — making SwiftUI buttons appear dead.
/// Returning true here delivers the click to the hosted SwiftUI gesture without making the
/// panel key or stealing focus from the frontmost app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
