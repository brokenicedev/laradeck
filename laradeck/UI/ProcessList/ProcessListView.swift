import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProcessListView: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let processes: [ProcessDefinition]
    var isStartOrderList: Bool = false
    /// When set, the sequence UI shows only these process ids (and optional root pauses).
    var sequenceFilterIds: Set<UUID>? = nil
    /// Whether root-level pause nodes appear in the filtered sequence (Processes only).
    var includeRootDelays: Bool = true
    /// Context-menu / insert pause actions for this list.
    var allowsSequencePauses: Bool = true
    /// When false (Other commands), drag is for attach-only — no reorder insertion lines.
    var allowsReorder: Bool = true
    /// Isolates drag/drop to this list so Other commands cannot attach onto Processes (and vice versa).
    var dragScope: String = "processes"
    let onOpenLogs: (String) -> Void

    @State private var dragState = SequenceDragState()

    private var displaySequence: [StartupSequenceNode] {
        let full = project.effectiveStartupSequence
        guard let allowed = sequenceFilterIds else { return full }
        return StartupSequence.filteredTree(
            full,
            allowing: allowed,
            includeRootDelays: includeRootDelays
        )
    }

    private var sequenceRows: [StartupSequenceRow] {
        StartupSequence.flattenedRows(displaySequence)
    }

    /// Other processes in this section that can be attach parents (same tab only).
    private var attachParentDefinitions: [ProcessDefinition] {
        processes.filter { definition in
            definition.type == .folderWatch || definition.type == .longRunning || definition.type == .oneShot
        }
    }

    var body: some View {
        Group {
            if isStartOrderList {
                sequenceList
            } else {
                staticList
            }
        }
        .laradeckCard(cornerRadius: 8)
    }

    private var staticList: some View {
        VStack(spacing: 0) {
            ForEach(Array(processes.enumerated()), id: \.element.id) { index, definition in
                ProcessRowView(
                    project: project,
                    definition: definition,
                    showsDragHandle: false,
                    onOpenLogs: onOpenLogs
                )
                if index < processes.count - 1 {
                    Divider()
                }
            }
            if processes.isEmpty {
                emptyPlaceholder
            }
        }
    }

    private var sequenceList: some View {
        VStack(spacing: 0) {
            ForEach(sequenceRows) { row in
                if allowsReorder {
                    SequenceReorderDropZone(
                        target: .before(row.id),
                        depth: row.depth,
                        dragScope: dragScope,
                        dragState: $dragState,
                        onDrop: { draggedId in
                            mutateSequence { StartupSequence.moveNode(withId: draggedId, beforeNodeId: row.id, in: &$0) }
                        }
                    )
                } else if sequenceRows.first?.id != row.id {
                    Divider()
                }

                sequenceRow(row)
                    .draggedRowOutline(isSource: dragState.draggedRowId == row.id)
            }

            if allowsReorder, let lastRow = sequenceRows.last {
                SequenceReorderDropZone(
                    target: .afterLast,
                    depth: lastRow.depth,
                    dragScope: dragScope,
                    dragState: $dragState,
                    onDrop: { draggedId in
                        mutateSequence { StartupSequence.moveNode(withId: draggedId, afterNodeId: lastRow.id, in: &$0) }
                    }
                )
            }

            if sequenceRows.isEmpty && processes.isEmpty {
                emptyPlaceholder
            } else if sequenceRows.isEmpty {
                Text("Drag processes here or add them to this group.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private func endDragSession() {
        dragState.clear()
        DragSessionEndMonitor.cancel()
        InAppSequenceDrag.end()
    }

    private func beginDragSession(rowId: UUID, depth: Int) {
        InAppSequenceDrag.begin()
        dragState.draggedRowId = rowId
        dragState.draggedRowDepth = depth
        // Only Escape cancels chrome; mouse-up is handled by dropDestination so highlight
        // stays visible for the whole drag (mouse-up used to clear state too early).
        DragSessionEndMonitor.watchEscape {
            endDragSession()
        }
    }

    @ViewBuilder
    private func sequenceRow(_ row: StartupSequenceRow) -> some View {
        let activeStep = activeSequenceStep(for: row.id)

        switch row.kind {
        case .process(let processId):
            if let definition = project.process(withId: processId) {
                let attachParents = attachParentDefinitions
                    .filter { $0.id != definition.id }
                    .map { (id: $0.id, name: $0.name) }

                let canAttachAbove = allowsReorder
                    ? previousDisplayProcessRowId(before: row.id) != nil
                    : previousDisplayProcessDefinitionId(before: row.id) != nil

                ProcessRowView(
                    project: project,
                    definition: definition,
                    showsDragHandle: true,
                    indentLevel: row.depth,
                    activeStep: activeStep,
                    onOpenLogs: onOpenLogs,
                    onInsertPauseBelow: allowsSequencePauses ? {
                        mutateSequence { StartupSequence.insertPause(afterNodeId: row.id, in: &$0) }
                    } : nil,
                    onAttachToProcessAbove: canAttachAbove ? {
                        if allowsReorder {
                            guard let parentNodeId = previousDisplayProcessRowId(before: row.id) else { return }
                            mutateSequence { sequence in
                                StartupSequence.nestNode(withId: row.id, underNodeId: parentNodeId, in: &sequence)
                            }
                        } else if let parentProcessId = previousDisplayProcessDefinitionId(before: row.id) {
                            mutateSequence { sequence in
                                StartupSequence.nestProcessDefinition(
                                    processId,
                                    underParentProcessId: parentProcessId,
                                    in: &sequence
                                )
                            }
                        }
                    } : nil,
                    attachParentOptions: attachParents,
                    onAttachUnderProcess: { parentProcessId in
                        mutateSequence { sequence in
                            StartupSequence.nestProcessDefinition(
                                processId,
                                underParentProcessId: parentProcessId,
                                in: &sequence
                            )
                        }
                    },
                    onDetach: row.depth > 0 ? {
                        if allowsReorder {
                            mutateSequence { StartupSequence.outdentNode(withId: row.id, in: &$0) }
                        } else {
                            mutateSequence { sequence in
                                StartupSequence.outdentProcessDefinition(processId, in: &sequence)
                            }
                        }
                    } : nil,
                    dragItemProvider: {
                        let payloadId = allowsReorder ? row.id : processId
                        beginDragSession(rowId: row.id, depth: row.depth)
                        return SequenceDragPasteboard.itemProvider(scope: dragScope, rowId: payloadId)
                    }
                )
                .sequenceNestDrop(
                    row: row,
                    dragScope: dragScope,
                    dragState: $dragState,
                    nestLabel: definition.name,
                    attachByProcessId: !allowsReorder,
                    onEndDrag: endDragSession,
                    onMutate: mutateSequence
                )
            }
        case .delay(let seconds):
            PauseRowView(
                seconds: seconds,
                depth: row.depth,
                row: row,
                dragScope: dragScope,
                dragState: $dragState,
                activeStep: activeStep,
                onBeginDrag: { beginDragSession(rowId: row.id, depth: row.depth) },
                onEndDrag: endDragSession,
                onMutate: mutateSequence,
                onRemove: {
                    mutateSequence { StartupSequence.removeNode(withId: row.id, from: &$0) }
                }
            )
        }
    }

    private func activeSequenceStep(for rowId: UUID) -> ActiveSequenceStep? {
        guard isStartOrderList else { return nil }
        if let step = appState.processManager.activeSequenceStep,
           step.projectId == project.id,
           step.nodeId == rowId {
            return step
        }
        // Attached children arm concurrently with their parent, so this is tracked separately
        // from the single top-level `activeSequenceStep` — see ProcessManager.isAttachedNodeActive.
        guard appState.processManager.isAttachedNodeActive(projectId: project.id, nodeId: rowId) else { return nil }
        return ActiveSequenceStep(projectId: project.id, nodeId: rowId)
    }

    /// Previous sibling process in the visible (possibly filtered) list — used for "Attach to Process Above".
    private func previousDisplayProcessRowId(before rowId: UUID) -> UUID? {
        guard let row = sequenceRows.first(where: { $0.id == rowId }) else { return nil }
        return StartupSequence.previousProcessRowId(before: row.path, in: displaySequence)
    }

    private func previousDisplayProcessDefinitionId(before rowId: UUID) -> UUID? {
        guard let parentRowId = previousDisplayProcessRowId(before: rowId),
              let parentRow = sequenceRows.first(where: { $0.id == parentRowId }),
              case .process(let processId) = parentRow.kind else { return nil }
        return processId
    }

    private var emptyPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            Text("No processes here yet — add a custom process to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func mutateSequence(_ transform: (inout [StartupSequenceNode]) -> Void) {
        var updated = project
        var sequence = updated.effectiveStartupSequence
        transform(&sequence)
        updated.startupSequence = sequence
        appState.updateProject(updated)
        endDragSession()
    }
}

// MARK: - Scoped drag payload helpers

private enum SequenceDragPayload {
    static func rowId(from item: LaradeckSequenceDragItem, matching scope: String) -> UUID? {
        guard item.scope == scope else { return nil }
        return item.rowId
    }
}

// MARK: - Drag state

private struct SequenceDragState: Equatable {
    var draggedRowId: UUID?
    var draggedRowDepth: Int = 0
    var dropTarget: SequenceDropTarget?

    var isDragging: Bool { draggedRowId != nil }

    mutating func clear() {
        DragSessionEndMonitor.cancel()
        draggedRowId = nil
        draggedRowDepth = 0
        dropTarget = nil
    }
}

private enum SequenceDropTarget: Equatable {
    case before(UUID)
    case nestUnder(UUID)
    case afterLast
}

// MARK: - Reorder drop zone (insertion line)

private enum SequenceRowLayout {
    static let horizontalPadding: CGFloat = 10
    static let dropZoneHeight: CGFloat = 8

    /// Leading inset for the blue insertion line — flush to the list edge at root, indented for nested rows.
    static func insertionLineLeadingInset(depth: Int) -> CGFloat {
        if depth == 0 {
            return horizontalPadding
        }
        return CGFloat(depth) * 20 + 36
    }
}

private struct SequenceReorderDropZone: View {
    let target: SequenceDropTarget
    let depth: Int
    let dragScope: String
    @Binding var dragState: SequenceDragState
    let onDrop: (UUID) -> Void

    @State private var isTargeted = false

    /// Only highlight when THIS list started the drag (blocks cross-section Other → Processes).
    private var isActive: Bool {
        dragState.isDragging && (isTargeted || dragState.dropTarget == target)
    }

    private var showsTopLevelHint: Bool {
        depth == 0 && dragState.draggedRowDepth > 0 && isActive
    }

    private var lineLeadingInset: CGFloat {
        SequenceRowLayout.insertionLineLeadingInset(depth: depth)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(height: SequenceRowLayout.dropZoneHeight)
                .contentShape(Rectangle())

            if isActive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                    if showsTopLevelHint {
                        Text("Top level")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.leading, lineLeadingInset)
                .padding(.trailing, SequenceRowLayout.horizontalPadding)
            }
        }
        .frame(height: SequenceRowLayout.dropZoneHeight)
        .dropDestination(for: LaradeckSequenceDragItem.self) { items, _ in
            defer { dragState.clear(); InAppSequenceDrag.end() }
            guard let item = items.first,
                  let draggedId = SequenceDragPayload.rowId(from: item, matching: dragScope) else {
                return false
            }
            guard draggedId != rowIdForTarget else { return false }
            onDrop(draggedId)
            return true
        } isTargeted: { targeted in
            guard dragState.isDragging else {
                isTargeted = false
                if dragState.dropTarget == target { dragState.dropTarget = nil }
                return
            }
            isTargeted = targeted
            if targeted {
                dragState.dropTarget = target
            } else if dragState.dropTarget == target {
                dragState.dropTarget = nil
            }
        }
    }

    private var rowIdForTarget: UUID? {
        switch target {
        case .before(let id), .nestUnder(let id): return id
        case .afterLast: return nil
        }
    }
}

// MARK: - Nest drop + highlight (no onDrag — that lives on the handle so context menus work)

private struct SequenceNestDropModifier: ViewModifier {
    let row: StartupSequenceRow
    let dragScope: String
    @Binding var dragState: SequenceDragState
    let nestLabel: String?
    var attachByProcessId: Bool = false
    let onEndDrag: () -> Void
    let onMutate: (@escaping (inout [StartupSequenceNode]) -> Void) -> Void

    @State private var isNestTargeted = false

    private var isEligibleTarget: Bool {
        guard case .process = row.kind else { return false }
        guard dragState.isDragging, let source = dragState.draggedRowId else { return false }
        return source != row.id
    }

    private var showsNestTarget: Bool {
        isEligibleTarget && (isNestTargeted || dragState.dropTarget == .nestUnder(row.id))
    }

    private var dropPayloadSelfId: UUID {
        if attachByProcessId, case .process(let processId) = row.kind {
            return processId
        }
        return row.id
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if case .process = row.kind, showsNestTarget {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange, lineWidth: 2)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Label("Attach to \(nestLabel ?? "process")", systemImage: "link")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.background, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
                                .padding(8)
                        }
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isEligibleTarget {
                    Color.clear
                        .contentShape(Rectangle())
                        .dropDestination(for: LaradeckSequenceDragItem.self) { items, _ in
                            performNestDrop(items)
                        } isTargeted: { targeted in
                            updateNestTargeting(targeted)
                        }
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsNestTarget)
            .dropDestination(for: LaradeckSequenceDragItem.self) { items, _ in
                // Accept drops even before isEligibleTarget overlay mounts (first frame of drag).
                performNestDrop(items)
            } isTargeted: { targeted in
                guard case .process = row.kind else {
                    isNestTargeted = false
                    return
                }
                // Highlight only when this list is the drag source (local dragState).
                guard dragState.isDragging, dragState.draggedRowId != row.id else {
                    isNestTargeted = false
                    if dragState.dropTarget == .nestUnder(row.id) {
                        dragState.dropTarget = nil
                    }
                    return
                }
                updateNestTargeting(targeted)
            }
    }

    private func performNestDrop(_ items: [LaradeckSequenceDragItem]) -> Bool {
        defer { onEndDrag() }
        guard case .process(let parentProcessId) = row.kind else { return false }
        guard let item = items.first,
              let draggedId = SequenceDragPayload.rowId(from: item, matching: dragScope),
              draggedId != dropPayloadSelfId else { return false }
        onMutate { sequence in
            if attachByProcessId {
                StartupSequence.nestProcessDefinition(
                    draggedId,
                    underParentProcessId: parentProcessId,
                    in: &sequence
                )
            } else {
                guard !StartupSequence.isNestedUnder(draggedId, parentNodeId: row.id, in: sequence) else { return }
                StartupSequence.nestNode(withId: draggedId, underNodeId: row.id, in: &sequence)
            }
        }
        return true
    }

    private func updateNestTargeting(_ targeted: Bool) {
        isNestTargeted = targeted
        if targeted {
            dragState.dropTarget = .nestUnder(row.id)
        } else if dragState.dropTarget == .nestUnder(row.id) {
            dragState.dropTarget = nil
        }
    }
}

private extension View {
    func sequenceNestDrop(
        row: StartupSequenceRow,
        dragScope: String,
        dragState: Binding<SequenceDragState>,
        nestLabel: String?,
        attachByProcessId: Bool = false,
        onEndDrag: @escaping () -> Void,
        onMutate: @escaping (@escaping (inout [StartupSequenceNode]) -> Void) -> Void
    ) -> some View {
        modifier(SequenceNestDropModifier(
            row: row,
            dragScope: dragScope,
            dragState: dragState,
            nestLabel: nestLabel,
            attachByProcessId: attachByProcessId,
            onEndDrag: onEndDrag,
            onMutate: onMutate
        ))
    }

    func draggedRowOutline(isSource: Bool) -> some View {
        overlay {
            if isSource {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Active step highlight

private struct SequenceRowActiveHighlight: ViewModifier {
    let isActive: Bool
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.16))
                }
            }
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint)
                        .frame(width: 3)
                        .padding(.vertical, 5)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

private extension View {
    func sequenceRowActiveHighlight(isActive: Bool, tint: Color) -> some View {
        modifier(SequenceRowActiveHighlight(isActive: isActive, tint: tint))
    }
}

// MARK: - Pause row

private struct PauseRowView: View {
    let seconds: Int
    let depth: Int
    let row: StartupSequenceRow
    let dragScope: String
    @Binding var dragState: SequenceDragState
    let activeStep: ActiveSequenceStep?
    let onBeginDrag: () -> Void
    let onEndDrag: () -> Void
    let onMutate: (@escaping (inout [StartupSequenceNode]) -> Void) -> Void
    let onRemove: () -> Void

    private var isActiveInSequence: Bool { activeStep != nil }

    private var displaySeconds: Int {
        activeStep?.delayRemaining ?? seconds
    }

    private var activeBadge: String? {
        guard isActiveInSequence else { return nil }
        if let remaining = activeStep?.delayRemaining {
            return remaining == 1 ? "1s left" : "\(remaining)s left"
        }
        return "Waiting…"
    }

    private var delayBinding: Binding<Int> {
        Binding(
            get: { seconds },
            set: { newValue in
                onMutate { sequence in
                    StartupSequence.updateNode(at: row.path, in: &sequence) { node in
                        node.kind = .delay(seconds: max(0, newValue))
                    }
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            timeline
                .padding(.leading, CGFloat(depth) * 20)

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .padding(6)
                .contentShape(Rectangle())
                .onDrag {
                    onBeginDrag()
                    return SequenceDragPasteboard.itemProvider(
                        scope: dragScope,
                        rowId: row.id
                    )
                }

            Label("Pause", systemImage: "clock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActiveInSequence ? .orange : .secondary)

            if isActiveInSequence, let badge = activeBadge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }

            Spacer()

            Stepper(value: delayBinding, in: 0...120) {
                Text("\(delayBinding.wrappedValue)s")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            .controlSize(.small)

            Button { onRemove() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove Pause")
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .sequenceRowActiveHighlight(isActive: isActiveInSequence, tint: .orange)
        .contextMenu {
            Button("Insert Pause Below") {
                onMutate { StartupSequence.insertPause(afterNodeId: row.id, in: &$0) }
            }
            Divider()
            Button("Remove Pause", role: .destructive) { onRemove() }
        }
        .draggedRowOutline(isSource: dragState.draggedRowId == row.id)
    }

    @ViewBuilder
    private var timeline: some View {
        VStack(spacing: 1) {
            Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2, height: 6)
            Text("+\(displaySeconds)s")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isActiveInSequence ? .orange : .orange.opacity(0.85))
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: displaySeconds)
            Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2, height: 6)
        }
        .frame(width: 28)
    }
}

// MARK: - Process row

private struct ProcessRowView: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let definition: ProcessDefinition
    var showsDragHandle: Bool = false
    var indentLevel: Int = 0
    var activeStep: ActiveSequenceStep? = nil
    let onOpenLogs: (String) -> Void
    var onInsertPauseBelow: (() -> Void)? = nil
    var onAttachToProcessAbove: (() -> Void)? = nil
    var attachParentOptions: [(id: UUID, name: String)] = []
    var onAttachUnderProcess: ((UUID) -> Void)? = nil
    var onDetach: (() -> Void)? = nil
    /// When set, drag starts from the handle only (keeps the row context menu working).
    var dragItemProvider: (() -> NSItemProvider)? = nil

    @State private var showingDependencyPrompt = false
    @State private var showingRemoveConfirmation = false
    @State private var showingEditSheet = false

    private var status: ProcessStatus {
        appState.processManager.status(for: definition.id)
    }

    private var succeededOneShot: Bool {
        guard definition.type == .oneShot || definition.type == .shortcut, status == .stopped else { return false }
        return appState.processManager.runningProcess(for: definition.id)?.exitCode == 0
    }

    private var isRunOnDemand: Bool {
        definition.type == .oneShot || definition.type == .shortcut
    }

    private var statusColor: Color {
        if succeededOneShot { return .green }
        if definition.type == .folderWatch {
            switch status {
            case .running, .starting: return .blue
            default: break
            }
        }
        if project.isOtherCommand(definition) {
            switch status {
            case .running, .starting: return .blue
            default: break
            }
        }
        return status.color
    }

    private var isActiveInSequence: Bool { activeStep != nil }

    private var activeTint: Color {
        if definition.type == .folderWatch, status == .running || status == .starting {
            return .blue
        }
        switch status {
        case .starting, .stopping: return .yellow
        case .running: return .green
        case .failed: return .red
        case .stopped: return .accentColor
        }
    }

    private var activeBadge: String? {
        guard isActiveInSequence else { return nil }
        switch status {
        case .starting: return definition.type == .folderWatch ? "Arming…" : "Starting…"
        case .running: return definition.type == .folderWatch ? "Watching" : "Running"
        case .stopping: return "Stopping…"
        case .failed: return "Failed"
        case .stopped: return "Up next"
        }
    }

    private var usesStartOrder: Bool {
        // Folder watches start on their own; nested children run later on filesystem changes.
        guard definition.type != .folderWatch, !isFolderWatchAction else { return false }
        return showsDragHandle && project.isIncludedInStartAll(definition)
    }

    /// Attached under a folder watch: it's the watch's action, so running it by hand means
    /// "do it now" — no need to start the earlier Start All steps first.
    private var isFolderWatchAction: Bool {
        guard let parentId = StartupSequence.parentProcessId(of: definition.id, in: project.effectiveStartupSequence),
              let parent = project.processes.first(where: { $0.id == parentId }) else { return false }
        return parent.type == .folderWatch
    }

    private var sequencePrerequisitesPending: Bool {
        guard usesStartOrder else { return false }
        let prereqs = StartupSequence.prerequisites(for: definition.id, in: project.effectiveStartupSequence)
        return prereqs.contains { node in
            if case .process(let id) = node.kind {
                return appState.processManager.status(for: id) != .running
            }
            return false
        }
    }

    private var dockerBlocksStart: Bool {
        project.hasDockerCompose && !appState.canStartProcesses(for: project)
    }

    private var startHelp: String {
        if dockerBlocksStart {
            return DockerManager.daemonUnavailableMessage
        }
        if usesStartOrder && sequencePrerequisitesPending {
            return "Earlier steps in the list must complete first"
        }
        return "Start"
    }

    var body: some View {
        HStack(spacing: 12) {
            if indentLevel > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(.leading, CGFloat(indentLevel) * 18)
            }

            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .padding(6)
                    .contentShape(Rectangle())
                    .modifier(OptionalOnDrag(provider: dragItemProvider))
            }

            StatusDotView(
                color: statusColor,
                pulsing: (project.isOtherCommand(definition) || definition.type == .folderWatch)
                    && (status == .running || status == .starting)
            )

            processIconBadge

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(definition.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    if indentLevel > 0 {
                        Text("attached")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.55), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if definition.isInteractiveCommand {
                        InteractiveCommandBadge()
                    }
                    if definition.type == .shortcut {
                        ShortcutBadge()
                    }
                    if isActiveInSequence, let badge = activeBadge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(activeTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(activeTint.opacity(0.12), in: Capsule())
                    }
                }
                Text(definition.commandLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let port = definition.port {
                PortBadgeView(ports: [port])
            }

            controls

            Divider().frame(height: 18)

            Button { onOpenLogs(definition.name) } label: {
                Image(systemName: definition.isInteractiveCommand ? "keyboard" : TerminalLauncher.logsIconSystemName)
            }
            .buttonStyle(.laradeckIcon(accent: definition.isInteractiveCommand ? InteractiveCommandBadge.tint : .secondary))
            .help(definition.isInteractiveCommand ? "Interactive Logs" : "View Logs")

            Button { showingRemoveConfirmation = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.laradeckIcon())
            .help("Remove Process")
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .sequenceRowActiveHighlight(isActive: isActiveInSequence, tint: activeTint)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { showingEditSheet = true }
        .contextMenu {
            Button("Edit…") { showingEditSheet = true }
            if status == .running || status == .failed {
                Button("Restart") {
                    appState.processManager.restart(definition, in: project)
                }
            }
            if let onInsertPauseBelow {
                Button("Insert Pause Below", action: onInsertPauseBelow)
            }
            if let onAttachToProcessAbove {
                Button("Attach to Process Above", action: onAttachToProcessAbove)
            }
            if let onAttachUnderProcess, !attachParentOptions.isEmpty {
                Menu("Attach under") {
                    ForEach(attachParentOptions, id: \.id) { parent in
                        Button(parent.name) {
                            onAttachUnderProcess(parent.id)
                        }
                    }
                }
            }
            if let onDetach {
                Button("Detach", action: onDetach)
            }
            Menu("Move to") {
                let current = ProcessDestination.from(groupId: definition.groupId, role: definition.effectiveRole)
                Button("Processes") { moveTo(.processes) }
                    .disabled(current == .processes)
                Button("Pre-start") { moveTo(.preStart) }
                    .disabled(current == .preStart)
                Button("Post-start") { moveTo(.postStart) }
                    .disabled(current == .postStart)
                Button("Post-stop") { moveTo(.postStop) }
                    .disabled(current == .postStop)
                ForEach(project.effectiveProcessGroups) { group in
                    Button(group.name) { moveTo(.group(group.id)) }
                        .disabled(current == .group(group.id))
                }
            }
            Divider()
            Button("Remove", role: .destructive) { showingRemoveConfirmation = true }
        }
        .confirmationDialog(
            "Start the steps above first, then \(definition.name)?",
            isPresented: $showingDependencyPrompt
        ) {
            Button("Start in Order") { startWithSequence() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove \(definition.name)?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { removeProcess() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingEditSheet) {
            CustomProcessSheet(project: project, editing: definition)
        }
    }

    private var processIconBadge: some View {
        let tint = iconBadgeTint
        return Image(systemName: definition.kind.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
    }

    private var iconBadgeTint: Color {
        switch status {
        case .running, .starting:
            return statusColor
        case .failed:
            return .red
        case .stopping:
            return .orange
        case .stopped:
            return succeededOneShot ? .green : Color.secondary
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch status {
        case .stopped, .failed:
            if isRunOnDemand {
                Button {
                    startFromControl()
                } label: {
                    Label("Run", systemImage: "play")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.laradeckOutline(compact: true))
                .disabled(dockerBlocksStart)
                .help(startHelp)
            } else {
                Button {
                    startFromControl()
                } label: {
                    Image(systemName: "play")
                }
                .buttonStyle(.laradeckIcon(accent: definition.type == .folderWatch ? .blue : .green))
                .disabled(dockerBlocksStart)
                .help(startHelp)
            }
        case .running:
            Button { appState.processManager.restart(definition, in: project) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.laradeckIcon())
            .help("Restart")
            Button { appState.processManager.stop(definition, in: project) } label: {
                Image(systemName: "stop")
            }
            .buttonStyle(.laradeckIcon(accent: .red))
            .help("Stop")
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        }
    }

    private func startFromControl() {
        if definition.type == .folderWatch {
            appState.startProcess(definition, in: project)
            return
        }
        if usesStartOrder {
            if sequencePrerequisitesPending {
                showingDependencyPrompt = true
            } else {
                Task { await appState.startProcessWithDependencies(definition, in: project) }
                openLogsIfInteractive()
            }
        } else {
            appState.startProcess(definition, in: project)
            openLogsIfInteractive()
        }
    }

    private func startWithSequence() {
        Task { await appState.startProcessWithDependencies(definition, in: project) }
        openLogsIfInteractive()
    }

    private func openLogsIfInteractive() {
        guard definition.isInteractiveCommand else { return }
        onOpenLogs(definition.name)
    }

    private func removeProcess() {
        if status != .stopped, status != .failed {
            appState.processManager.stop(definition, in: project)
        }
        var updated = project
        updated.processes.removeAll { $0.id == definition.id }
        if var sequence = updated.startupSequence {
            StartupSequence.removeProcess(definition.id, from: &sequence)
            updated.startupSequence = sequence
        }
        appState.updateProject(updated)
    }

    private func moveTo(_ destination: ProcessDestination) {
        var updated = project
        guard let index = updated.processes.firstIndex(where: { $0.id == definition.id }) else { return }
        updated.processes[index].groupId = destination.groupId
        updated.processes[index].role = destination.role
        appState.updateProject(updated)
    }
}

/// Applies `.onDrag` only when a provider is available (avoids breaking context menus on the row).
private struct OptionalOnDrag: ViewModifier {
    let provider: (() -> NSItemProvider)?

    func body(content: Content) -> some View {
        if let provider {
            content.onDrag(provider)
        } else {
            content
        }
    }
}

// MARK: - Drag session monitor

/// Clears drag UI chrome on Escape. Drop destinations clear state on successful/failed drop;
/// we intentionally do not listen for mouse-up (it races with nest highlight during the drag).
@MainActor
private enum DragSessionEndMonitor {
    private static var monitor: Any?

    static func watchEscape(onEnd: @escaping @MainActor () -> Void) {
        cancel()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    cancel()
                    onEnd()
                }
            }
            return event
        }
    }

    static func cancel() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
