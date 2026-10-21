import AppKit
import SwiftUI

extension View {
    /// Thin scrollbar that only shows while scrolling, even when System Settings
    /// is set to always show scroll bars (which makes SwiftUI use the wide legacy style).
    func overlayScrollers() -> some View {
        background(OverlayScrollerConfigurator())
    }
}

private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollerProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Finds the enclosing NSScrollView once it's in a window and switches its style.
    private final class ScrollerProbe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // The user can flip the system setting while the app runs; AppKit then resets the style.
            observer = observer ?? NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView ?? self?.findScrollView() else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
        }

        /// `.background` puts the probe beside the scroll view's content, not inside it.
        private func findScrollView() -> NSScrollView? {
            var view: NSView? = superview
            while let current = view {
                if let scroll = current.subviews.lazy.compactMap({ $0 as? NSScrollView }).first { return scroll }
                if let scroll = current as? NSScrollView { return scroll }
                view = current.superview
            }
            return nil
        }
    }
}
