import AppKit
import SwiftUI

/// MenuBarExtra grows its window when the content grows, but never shrinks it.
/// The content then floats in the middle of a taller, empty window, far below the menu bar.
/// This keeps the window exactly as tall as the content, with the top edge where macOS put it.
struct WindowFitter: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let size = size
        // The window is attached after the first update, and a resize inside a layout pass is ignored.
        DispatchQueue.main.async { Self.fit(view.window, to: size) }
    }

    static func fit(_ window: NSWindow?, to size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let frame = window.frame
        guard abs(frame.height - target.height) >= 0.5 || abs(frame.width - target.width) >= 0.5 else { return }
        // AppKit keeps the bottom-left corner. Keep the top-left corner instead, under the menu bar.
        let origin = NSPoint(x: frame.minX, y: frame.maxY - target.height)
        window.setFrame(NSRect(origin: origin, size: target), display: true)
    }
}

extension View {
    /// Sizes the hosting window to this view's size. See `WindowFitter`.
    func fitsWindow() -> some View {
        background(
            GeometryReader { proxy in
                WindowFitter(size: proxy.size)
            }
        )
    }
}
