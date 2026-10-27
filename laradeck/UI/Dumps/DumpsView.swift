import AppKit
import DumpKit
import SwiftUI

/// A project's dump stream. Shown in place of the dashboard (`onDone` returns to it) or in its
/// own window (`isDetached`), where "Reattach" brings it back into the main window.
struct DumpsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    let target: DumpTarget
    var isDetached = false
    var onDone: (() -> Void)?

    private var service: DumpService { appState.dumpService }

    var body: some View {
        let session = service.session(for: target)
        let theme = ThemeStore.shared.theme
        let items = session.visibleItems(groupDuplicates: service.groupDuplicates)

        VStack(spacing: 0) {
            DumpsHeaderBar(target: target, isDetached: isDetached, onDetach: detach, onReattach: reattach)
            Rectangle().fill(theme.border).frame(height: 1)

            if service.enabled, case .failed(let port, let message) = service.serverState {
                DumpsServerBanner(name: "dump", port: port, message: message) { service.restartServer() }
            }
            if service.enabled, service.dsEnabled, case .failed(let port, let message) = service.dsServerState {
                DumpsServerBanner(name: "ds()", port: port, message: message) { service.restartDsServer() }
            }
            if !service.enabled {
                NoticeBanner(tone: .info, message: "The dump server is off. Turn it on in Settings → Dumps.")
                    .padding(12)
            }
            if session.store.isPaused {
                Text("Paused. New messages are ignored.")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(Color.orange.opacity(0.2))
            }

            ZStack {
                if items.isEmpty {
                    DumpsEmptyState(hasEntries: !session.store.currentScreen.entries.isEmpty, port: service.port)
                } else {
                    DumpListView(items: items)
                }
                DumpConfettiView(trigger: session.store.confettiCounter)
                    .allowsHitTesting(false)
            }
            // Rebuild rows when the theme changes so dump colors refresh.
            .id(theme.name)
        }
        .environment(session)
        .foregroundStyle(theme.text)
        .background {
            ThemeBackground(tint: session.store.screenColor.map { DumpColor.color($0) })
        }
        .laradeckTitle(navigationTitle)
        .toolbar {
            if let onDone, !isDetached {
                ToolbarItem(placement: .navigation) {
                    Button {
                        onDone()
                    } label: {
                        Label("Dashboard", systemImage: "chevron.left")
                    }
                }
            }
        }
        .onAppear { service.setVisible(target, true) }
        .onDisappear { service.setVisible(target, false) }
    }

    private var navigationTitle: String {
        "\(service.title(for: target)) — Dumps"
    }

    private func detach() {
        DumpsWindow.open(target, service: service, openWindow: openWindow)
        onDone?()
    }

    private func reattach() {
        if case .project(let id) = target {
            appState.selectedProjectId = id
            appState.pendingDumpsOpen = id
        }
        dismissWindow(id: DumpsWindow.id)
        DumpsWindow.focusMainWindow()
    }
}

/// Scene helpers for the detached dumps window.
enum DumpsWindow {
    static let id = "dumps"

    /// Opens (or brings forward) the Dumps window, switching it to `target` when given.
    @MainActor
    static func open(_ target: DumpTarget?, service: DumpService, openWindow: OpenWindowAction) {
        if let target { service.windowTarget = target }
        openWindow(id: id)
    }

    /// Brings the main Laradeck window forward (the one that isn't a dumps window).
    static func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first {
            $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.hasPrefix(id) != true
        }
        main?.makeKeyAndOrderFront(nil)
    }
}

/// The Dumps window: a project picker on top of the chosen stream, or an empty page.
struct DetachedDumpsWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let service = appState.dumpService
        Group {
            if let target = service.windowTarget {
                DumpsView(target: target, isDetached: true)
                    .id(target)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        DumpsTargetPicker()
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ThemeStore.shared.theme.header.opacity(0.6))
                    Rectangle().fill(ThemeStore.shared.theme.border).frame(height: 1)
                    DumpsWindowEmptyPage(hasProjects: !service.pickerTargets.isEmpty)
                }
                .background { ThemeBackground() }
                .laradeckTitle("Dumps")
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { service.isWindowOpen = true }
        .onDisappear { service.isWindowOpen = false }
    }
}

/// Window project switcher: projects with dumps, plus Unassigned.
struct DumpsTargetPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let service = appState.dumpService
        let current = service.windowTarget
        Menu {
            let targets = service.pickerTargets
            if targets.isEmpty {
                Text("No projects with dumps yet")
            }
            ForEach(targets, id: \.self) { target in
                Button {
                    service.windowTarget = target
                } label: {
                    let title = pickerTitle(target, service: service)
                    if target == current {
                        Label(title, systemImage: "checkmark")
                    } else if service.existingSession(for: target)?.unreadErrorCount ?? 0 > 0 {
                        Label(title, systemImage: "exclamationmark.triangle")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Label(current.map { service.title(for: $0) } ?? "Choose project",
                  systemImage: current == .unassigned ? "tray" : "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch project")
    }

    private func pickerTitle(_ target: DumpTarget, service: DumpService) -> String {
        let session = service.existingSession(for: target)
        let count = session?.store.currentScreen.entries.count ?? 0
        let unread = session?.unreadCount ?? 0
        return "\(service.title(for: target)) (\(count))" + (unread > 0 ? " · \(unread) new" : "")
    }
}

private struct DumpsWindowEmptyPage: View {
    let hasProjects: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(hasProjects ? "Choose a project" : "No dumps yet").font(.headline)
            Text(hasProjects
                 ? "Pick a project from the menu above to follow its dumps here."
                 : "Projects show up in the menu above as soon as they send a dump.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasProjects {
                HStack(spacing: 10) {
                    ForEach(["ray('Hello world');", "ds('Hello world');"], id: \.self) { code in
                        Text(code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Header

private struct DumpsHeaderBar: View {
    @Environment(AppState.self) private var appState
    @Environment(DumpSession.self) private var session
    @Environment(\.openWindow) private var openWindow

    let target: DumpTarget
    let isDetached: Bool
    let onDetach: () -> Void
    let onReattach: () -> Void

    private var service: DumpService { appState.dumpService }

    var body: some View {
        HStack(spacing: 10) {
            if isDetached {
                DumpsTargetPicker()
                Divider().frame(height: 16)
            }
            screensMenu
            DumpsSearchField()
            DumpsColorFilterBar()

            Spacer(minLength: 8)

            if case .project = target, service.unassignedCount > 0, !isDetached {
                Button {
                    DumpsWindow.open(.unassigned, service: service, openWindow: openWindow)
                } label: {
                    Label("Unassigned (\(service.unassignedCount))", systemImage: "tray")
                }
                .buttonStyle(.laradeckOutline(compact: true))
                .help("Dumps that didn't match any project")
            }

            Button {
                session.store.isPaused.toggle()
            } label: {
                Image(systemName: session.store.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.laradeckOutline(compact: true))
            .help(session.store.isPaused ? "Resume" : "Pause")

            Button {
                session.store.clearCurrentScreen()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.laradeckOutline(accent: .red, compact: true))
            .keyboardShortcut("k", modifiers: .command)
            .help("Clear messages (⌘K)")

            if case .project = target {
                if isDetached {
                    Button(action: onReattach) {
                        Label("Reattach", systemImage: "rectangle.portrait.and.arrow.forward")
                    }
                    .buttonStyle(.laradeckOutline(compact: true))
                    .help("Move back into the project dashboard")
                } else {
                    Button(action: onDetach) {
                        Label("Detach", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.laradeckOutline(compact: true))
                    .help("Open in a separate window")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ThemeStore.shared.theme.header.opacity(0.6))
    }

    private var screensMenu: some View {
        Menu {
            ForEach(session.store.screens) { screen in
                Button {
                    session.store.currentScreenID = screen.id
                } label: {
                    if screen.id == session.store.currentScreenID {
                        Label("\(screen.name) (\(screen.entries.count))", systemImage: "checkmark")
                    } else {
                        Text("\(screen.name) (\(screen.entries.count))")
                    }
                }
            }
            Divider()
            Button("New Screen") { session.store.newScreen() }
            Button("Delete This Screen") { session.store.deleteScreen(session.store.currentScreenID) }
            if !session.store.archived.isEmpty {
                Divider()
                Button("Clear Archive (\(session.store.archived.count))") { session.store.clearArchive() }
            }
        } label: {
            Label(session.store.currentScreen.name, systemImage: "rectangle.stack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Screens")
    }
}

/// Search box; ⌘F focuses it.
private struct DumpsSearchField: View {
    @Environment(DumpSession.self) private var session
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var session = session
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search…", text: $session.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { session.searchText = ""; focused = false }
            if !session.searchText.isEmpty {
                Button { session.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(width: 180)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .onChange(of: session.searchFocusRequest) { focused = true }
    }
}

private struct DumpsColorFilterBar: View {
    @Environment(DumpSession.self) private var session

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DumpColor.names, id: \.self) { name in
                let on = session.colorFilter.contains(name)
                Button {
                    if on { session.colorFilter.remove(name) } else { session.colorFilter.insert(name) }
                } label: {
                    Circle()
                        .fill(DumpColor.color(name))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.primary.opacity(on ? 0.9 : 0), lineWidth: 2))
                        .opacity(session.colorFilter.isEmpty || on ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .help("Show only \(name) messages")
            }
        }
    }
}

// MARK: - List

struct DumpListView: View {
    @Environment(AppState.self) private var appState
    @Environment(DumpSession.self) private var session
    let items: [DumpSession.DisplayItem]

    var body: some View {
        let service = appState.dumpService
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: service.compactUI ? 2 : 6) {
                    ForEach(items) { item in
                        DumpRowView(entry: item.entry, count: item.count)
                            .id(item.id)
                    }
                }
                .padding(service.compactUI ? 4 : 12)
            }
            .onChange(of: session.store.lastAppendedID) {
                guard service.scrollOnLog, let last = items.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Banners and empty state

private struct DumpsServerBanner: View {
    let name: String
    let port: UInt16
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Couldn't start the \(name) server on port \(String(port)). \(message)")
                .font(.callout)
            Spacer()
            Button("Retry", action: onRetry)
            SettingsLink { Text("Change Port") }
        }
        .padding(8)
        .background(Color.red.opacity(0.15))
    }
}

private struct DumpsEmptyState: View {
    let hasEntries: Bool
    let port: Int

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            if hasEntries {
                Text("No messages match the current filters.").font(.headline)
            } else {
                Text("No dumps yet").font(.headline)
                Text("Call one of these from this project and the output shows up here.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(["ray('Hello world');", "ds('Hello world');"], id: \.self) { code in
                        Text(code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text("Listening on localhost:\(String(port)).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct DumpConfettiView: View {
    let trigger: Int
    @State private var start: Date?
    @State private var pieces: [Piece] = []

    struct Piece {
        var x: Double, drift: Double, speed: Double, spin: Double, color: Color, size: Double
    }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            Canvas { ctx, size in
                guard let start else { return }
                let t = timeline.date.timeIntervalSince(start)
                for p in pieces {
                    let y = -20 + t * p.speed * size.height / 2.2
                    let x = p.x * size.width + sin(t * 3 + p.drift) * 30
                    guard y < size.height + 20 else { continue }
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(t * p.spin))
                    c.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)), with: .color(p.color))
                }
            }
        }
        .onChange(of: trigger) {
            let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
            pieces = (0..<160).map { _ in
                Piece(x: .random(in: 0...1), drift: .random(in: 0...6), speed: .random(in: 0.6...1.4),
                      spin: .random(in: -8...8), color: colors.randomElement()!, size: .random(in: 6...12))
            }
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if let s = start, Date().timeIntervalSince(s) >= 3.4 { start = nil }
            }
        }
    }
}
