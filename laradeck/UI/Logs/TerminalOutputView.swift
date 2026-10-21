import SwiftUI
import SwiftTerm

/// Renders a `TerminalBufferSource`'s raw byte stream through SwiftTerm's own terminal engine —
/// real ANSI color/style interpretation, not just a hand-rolled approximation. Used for both live
/// process output and the tailed Laravel log, so every source in the Logs screen looks the same.
/// When `isInteractive` is true, keystrokes are forwarded to the live process PTY.
struct TerminalOutputView: NSViewRepresentable {
    let source: TerminalBufferSource?
    var isInteractive = false
    /// Whether the thing feeding this source (a process, `docker compose`, …) is still running.
    /// On the false edge, the view is forced back to the bottom — a burst of output right before
    /// a long command exits can leave SwiftTerm's own scroll-follow stuck mid-buffer, which would
    /// otherwise hide the last lines right when they matter most.
    var isActive = true
    var onSend: ((ArraySlice<UInt8>) -> Void)?
    var onSizeChanged: ((Int, Int) -> Void)?
    /// Light-on-dark colors for the docked log panel (same in light and dark mode).
    var usesPanelColors = false

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        if usesPanelColors {
            view.nativeBackgroundColor = LogPanelStyle.nsBackground
            view.nativeForegroundColor = LogPanelStyle.nsForeground
        }
        return view
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.isInteractive = isInteractive
        context.coordinator.isActive = isActive
        context.coordinator.onSend = onSend
        context.coordinator.onSizeChanged = onSizeChanged
        context.coordinator.sync(view: nsView, source: source)

        if isInteractive {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var isInteractive = false
        var isActive = true
        var onSend: ((ArraySlice<UInt8>) -> Void)?
        var onSizeChanged: ((Int, Int) -> Void)?

        private var feedByteCount = 0
        private var lastGeneration = -1
        private var lastSourceIdentity: ObjectIdentifier?
        private var wasActive = true

        /// Full VT100 reset (clears screen + scrollback) — used both when switching which source
        /// is shown and when a buffer was reset after hitting its size cap.
        private static let resetSequence: [UInt8] = Array("\u{1B}c".utf8)

        func sync(view: SwiftTerm.TerminalView, source: TerminalBufferSource?) {
            guard let source else {
                if lastSourceIdentity != nil {
                    view.feed(byteArray: Self.resetSequence[...])
                    lastSourceIdentity = nil
                    lastGeneration = -1
                    feedByteCount = 0
                }
                wasActive = isActive
                return
            }

            let identity = ObjectIdentifier(source)
            let switchedSource = identity != lastSourceIdentity
            let bufferWasReset = source.terminalGeneration != lastGeneration

            if switchedSource || bufferWasReset {
                view.feed(byteArray: Self.resetSequence[...])
                let bytes = [UInt8](source.terminalData)
                view.feed(byteArray: bytes[...])
                feedByteCount = bytes.count
                lastGeneration = source.terminalGeneration
                lastSourceIdentity = identity
                wasActive = isActive
                return
            }

            if source.terminalData.count > feedByteCount {
                let newBytes = [UInt8](source.terminalData.suffix(from: feedByteCount))
                view.feed(byteArray: newBytes[...])
                feedByteCount = source.terminalData.count
            }

            if wasActive && !isActive {
                view.scroll(toPosition: 1.0)
            }
            wasActive = isActive
        }

        // MARK: - TerminalViewDelegate

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard isInteractive else { return }
            onSizeChanged?(newCols, newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard isInteractive else { return }
            onSend?(data)
        }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
