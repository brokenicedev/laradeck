import Foundation

/// One step in the project's Start All timeline — a process or a pause.
nonisolated enum StartupSequenceKind: Codable, Hashable {
    case process(UUID)
    case delay(seconds: Int)
}

/// A node in the startup tree; process nodes can own nested steps that run after they are up.
nonisolated struct StartupSequenceNode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: StartupSequenceKind
    var children: [StartupSequenceNode] = []

    init(id: UUID = UUID(), kind: StartupSequenceKind, children: [StartupSequenceNode] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }
}

/// Flattened row for rendering the sequence editor.
nonisolated struct StartupSequenceRow: Identifiable, Hashable {
    let id: UUID
    let depth: Int
    let kind: StartupSequenceKind
    /// Path indices from the root array to this node.
    let path: [Int]
}

/// Which startup-sequence row is currently executing (Start All / ordered start).
nonisolated struct ActiveSequenceStep: Equatable {
    let projectId: UUID
    let nodeId: UUID
    /// Countdown while a pause node is active.
    var delayRemaining: Int?
}

nonisolated enum StartupSequence {
    static func sync(into sequence: inout [StartupSequenceNode], project: Project) {
        let validIds = Set(project.processes.map(\.id))
        removeInvalidProcesses(from: &sequence, validIds: validIds)
        removeDuplicateProcesses(from: &sequence)

        let referenced = Set(collectProcessIds(sequence))
        for definition in project.processes where Self.isSequenceMember(definition, project: project) && !referenced.contains(definition.id) {
            sequence.append(StartupSequenceNode(kind: .process(definition.id)))
        }
    }

    /// Processes that appear in a sequence UI (Start All members and Other commands for nesting).
    static func isSequenceMember(_ definition: ProcessDefinition, project: Project) -> Bool {
        guard definition.effectiveRole == .normal else { return false }
        if project.isIncludedInStartAll(definition) { return true }
        return project.isOtherCommand(definition)
    }

    static func defaultSequence(for project: Project) -> [StartupSequenceNode] {
        project.processes
            .filter { isSequenceMember($0, project: project) }
            .map { StartupSequenceNode(kind: .process($0.id)) }
    }

    /// Keeps nesting among `allowedIds`; drops other process nodes (promoting their allowed descendants).
    /// Root-level delays are kept only when `includeRootDelays` is true (Processes Start All list).
    static func filteredTree(
        _ nodes: [StartupSequenceNode],
        allowing allowedIds: Set<UUID>,
        includeRootDelays: Bool = false
    ) -> [StartupSequenceNode] {
        // A pause only makes sense positioned inside the process subtree it was inserted in. When
        // that owning process is excluded from this view, its children get promoted up a level —
        // but a pause has no identity of its own to promote, so it's dropped rather than spliced
        // into a list it was never part of (this is what used to leak a "Processes" pause into the
        // "Other commands" section whenever it sat under a process that section doesn't show).
        func filterChildren(_ children: [StartupSequenceNode], forPromotion: Bool) -> [StartupSequenceNode] {
            var result: [StartupSequenceNode] = []
            for child in children {
                switch child.kind {
                case .process(let id):
                    if allowedIds.contains(id) {
                        var copy = child
                        copy.children = filterChildren(child.children, forPromotion: false)
                        result.append(copy)
                    } else {
                        result.append(contentsOf: filterChildren(child.children, forPromotion: true))
                    }
                case .delay:
                    guard !forPromotion else { continue }
                    var copy = child
                    copy.children = filterChildren(child.children, forPromotion: false)
                    result.append(copy)
                }
            }
            return result
        }

        var result: [StartupSequenceNode] = []
        for node in nodes {
            switch node.kind {
            case .delay:
                if includeRootDelays {
                    var copy = node
                    copy.children = filterChildren(node.children, forPromotion: false)
                    result.append(copy)
                }
            case .process(let id):
                if allowedIds.contains(id) {
                    var copy = node
                    copy.children = filterChildren(node.children, forPromotion: false)
                    result.append(copy)
                } else {
                    result.append(contentsOf: filterChildren(node.children, forPromotion: true))
                }
            }
        }
        return result
    }

    /// Replaces the sequence with a flat list of processes in drag order (Start All follows this).
    static func applyFlatOrder(_ processIds: [UUID]) -> [StartupSequenceNode] {
        processIds.map { StartupSequenceNode(kind: .process($0)) }
    }

    static func collectProcessIds(_ nodes: [StartupSequenceNode]) -> [UUID] {
        nodes.flatMap { collectProcessIds($0) }
    }

    static func collectProcessIds(_ node: StartupSequenceNode) -> [UUID] {
        var ids: [UUID] = []
        if case .process(let processId) = node.kind {
            ids.append(processId)
        }
        for child in node.children {
            ids.append(contentsOf: collectProcessIds(child))
        }
        return ids
    }

    static func removeProcess(_ processId: UUID, from nodes: inout [StartupSequenceNode]) {
        nodes.removeAll { if case .process(processId) = $0.kind { return true }; return false }
        for index in nodes.indices {
            removeProcess(processId, from: &nodes[index].children)
        }
    }

    private static func removeInvalidProcesses(from nodes: inout [StartupSequenceNode], validIds: Set<UUID>) {
        nodes.removeAll { if case .process(let id) = $0.kind { return !validIds.contains(id) }; return false }
        for index in nodes.indices {
            removeInvalidProcesses(from: &nodes[index].children, validIds: validIds)
        }
    }

    /// Keeps the first occurrence of each process id (depth-first); drops later duplicates.
    private static func removeDuplicateProcesses(from nodes: inout [StartupSequenceNode], seen: inout Set<UUID>) {
        var index = 0
        while index < nodes.count {
            if case .process(let id) = nodes[index].kind {
                if seen.contains(id) {
                    nodes.remove(at: index)
                    continue
                }
                seen.insert(id)
            }
            removeDuplicateProcesses(from: &nodes[index].children, seen: &seen)
            index += 1
        }
    }

    private static func removeDuplicateProcesses(from nodes: inout [StartupSequenceNode]) {
        var seen = Set<UUID>()
        removeDuplicateProcesses(from: &nodes, seen: &seen)
    }

    static func flattenedRows(_ nodes: [StartupSequenceNode], depth: Int = 0, pathPrefix: [Int] = []) -> [StartupSequenceRow] {
        var rows: [StartupSequenceRow] = []
        for (index, node) in nodes.enumerated() {
            let path = pathPrefix + [index]
            rows.append(StartupSequenceRow(id: node.id, depth: depth, kind: node.kind, path: path))
            if case .process = node.kind, !node.children.isEmpty {
                rows.append(contentsOf: flattenedRows(node.children, depth: depth + 1, pathPrefix: path))
            }
        }
        return rows
    }

    /// Start All order: siblings at each level first, then nested steps under each process.
    static func executionOrder(_ nodes: [StartupSequenceNode]) -> [StartupSequenceNode] {
        var order: [StartupSequenceNode] = []
        appendExecutionOrder(nodes, to: &order)
        return order
    }

    private static func appendExecutionOrder(_ nodes: [StartupSequenceNode], to order: inout [StartupSequenceNode]) {
        for node in nodes {
            order.append(node)
        }
        for node in nodes where node.children.isEmpty == false {
            if case .process = node.kind {
                appendExecutionOrder(node.children, to: &order)
            }
        }
    }

    static func prerequisites(for processId: UUID, in nodes: [StartupSequenceNode]) -> [StartupSequenceNode] {
        var result: [StartupSequenceNode] = []
        for node in executionOrder(nodes) {
            if case .process(let id) = node.kind, id == processId {
                break
            }
            result.append(node)
        }
        return result
    }

    static func node(at path: [Int], in nodes: [StartupSequenceNode]) -> StartupSequenceNode? {
        var list = nodes
        var current: StartupSequenceNode?
        for index in path {
            guard index >= 0, index < list.count else { return nil }
            current = list[index]
            list = current?.children ?? []
        }
        return current
    }

    static func parentList(for path: [Int], in nodes: [StartupSequenceNode]) -> [StartupSequenceNode]? {
        if path.count <= 1 { return nodes as [StartupSequenceNode]? }
        guard let parent = node(at: Array(path.dropLast()), in: nodes) else { return nil }
        if case .process = parent.kind { return parent.children }
        return nil
    }

    static func removeNode(at path: [Int], from nodes: inout [StartupSequenceNode]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            guard first >= 0, first < nodes.count else { return }
            nodes.remove(at: first)
            return
        }
        guard first >= 0, first < nodes.count else { return }
        var childPath = Array(path.dropFirst())
        removeNode(at: childPath, from: &nodes[first].children)
    }

    static func insert(_ node: StartupSequenceNode, atIndex index: Int, pathToParent: [Int], into nodes: inout [StartupSequenceNode]) {
        if pathToParent.isEmpty {
            nodes.insert(node, at: min(max(index, 0), nodes.count))
            return
        }
        guard pathToParent.first! >= 0, pathToParent.first! < nodes.count else { return }
        if pathToParent.count == 1 {
            nodes[pathToParent[0]].children.insert(node, at: min(max(index, 0), nodes[pathToParent[0]].children.count))
            return
        }
        var childPath = Array(pathToParent.dropFirst())
        insert(node, atIndex: index, pathToParent: childPath, into: &nodes[pathToParent[0]].children)
    }

    static func moveNode(from sourcePath: [Int], toIndex destinationIndex: Int, pathToParent: [Int], in nodes: inout [StartupSequenceNode]) {
        guard let extracted = extractNode(at: sourcePath, from: &nodes) else { return }
        insert(extracted, atIndex: destinationIndex, pathToParent: pathToParent, into: &nodes)
    }

    static func nestNode(from sourcePath: [Int], under processPath: [Int], in nodes: inout [StartupSequenceNode]) {
        guard let parentId = node(at: processPath, in: nodes)?.id,
              case .process = node(at: processPath, in: nodes)?.kind else { return }
        // Reject nesting a node under one of its own descendants.
        if let draggedId = node(at: sourcePath, in: nodes)?.id,
           isNestedUnder(parentId, parentNodeId: draggedId, in: nodes) {
            return
        }
        guard let extracted = extractNode(at: sourcePath, from: &nodes) else { return }
        // Re-resolve parent path after extraction — earlier siblings shift indices.
        guard let newParentPath = path(to: parentId, in: nodes),
              case .process = node(at: newParentPath, in: nodes)?.kind else {
            nodes.append(extracted)
            return
        }
        updateNode(at: newParentPath, in: &nodes) { $0.children.append(extracted) }
    }

    static func outdentNode(at path: [Int], in nodes: inout [StartupSequenceNode]) {
        guard path.count >= 2 else { return }
        guard let extracted = extractNode(at: path, from: &nodes) else { return }
        let grandparentPath = Array(path.dropLast(2))
        let insertIndex = path[path.count - 2] + 1
        insert(extracted, atIndex: insertIndex, pathToParent: grandparentPath, into: &nodes)
    }

    static func updateNode(at path: [Int], in nodes: inout [StartupSequenceNode], _ transform: (inout StartupSequenceNode) -> Void) {
        guard let first = path.first, first >= 0, first < nodes.count else { return }
        if path.count == 1 {
            transform(&nodes[first])
            return
        }
        updateNode(at: Array(path.dropFirst()), in: &nodes[first].children, transform)
    }

    static func path(to nodeId: UUID, in nodes: [StartupSequenceNode], currentPath: [Int] = []) -> [Int]? {
        for (index, node) in nodes.enumerated() {
            let nodePath = currentPath + [index]
            if node.id == nodeId { return nodePath }
            if let found = path(to: nodeId, in: node.children, currentPath: nodePath) {
                return found
            }
        }
        return nil
    }

    /// Finds the sequence node that wraps a process definition (not the node's UUID).
    static func nodeForProcessId(_ processId: UUID, in nodes: [StartupSequenceNode]) -> StartupSequenceNode? {
        for node in nodes {
            if case .process(let id) = node.kind, id == processId {
                return node
            }
            if let nested = nodeForProcessId(processId, in: node.children) {
                return nested
            }
        }
        return nil
    }

    static func moveNode(withId draggedId: UUID, afterNodeId targetId: UUID, in nodes: inout [StartupSequenceNode]) {
        guard draggedId != targetId,
              let sourcePath = path(to: draggedId, in: nodes),
              path(to: targetId, in: nodes) != nil else { return }
        guard let extracted = extractNode(at: sourcePath, from: &nodes) else { return }
        guard let targetPath = path(to: targetId, in: nodes) else { return }
        let parentPath = Array(targetPath.dropLast())
        let insertIndex = (targetPath.last ?? 0) + 1
        insert(extracted, atIndex: insertIndex, pathToParent: parentPath, into: &nodes)
    }

    static func moveNode(withId draggedId: UUID, beforeNodeId targetId: UUID, in nodes: inout [StartupSequenceNode]) {
        guard draggedId != targetId,
              let sourcePath = path(to: draggedId, in: nodes),
              path(to: targetId, in: nodes) != nil else { return }
        guard let extracted = extractNode(at: sourcePath, from: &nodes) else { return }
        guard let targetPath = path(to: targetId, in: nodes) else { return }
        let parentPath = Array(targetPath.dropLast())
        let insertIndex = targetPath.last ?? 0
        insert(extracted, atIndex: insertIndex, pathToParent: parentPath, into: &nodes)
    }

    static func moveNodeToRoot(withId draggedId: UUID, atIndex index: Int, in nodes: inout [StartupSequenceNode]) {
        guard let sourcePath = path(to: draggedId, in: nodes) else { return }
        guard let extracted = extractNode(at: sourcePath, from: &nodes) else { return }
        insert(extracted, atIndex: index, pathToParent: [], into: &nodes)
    }

    static func isNestedUnder(_ nodeId: UUID, parentNodeId: UUID, in nodes: [StartupSequenceNode]) -> Bool {
        guard let parentPath = path(to: parentNodeId, in: nodes),
              let nodePath = path(to: nodeId, in: nodes),
              nodePath.count > parentPath.count else { return false }
        return Array(nodePath.prefix(parentPath.count)) == parentPath
    }

    static func previousProcessRowId(before path: [Int], in nodes: [StartupSequenceNode]) -> UUID? {
        guard let index = path.last, index > 0 else { return nil }
        let parentPath = Array(path.dropLast())
        let siblings = parentPath.isEmpty ? nodes : (node(at: parentPath, in: nodes)?.children ?? [])
        for i in stride(from: index - 1, through: 0, by: -1) where i < siblings.count {
            if case .process = siblings[i].kind { return siblings[i].id }
        }
        return nil
    }

    static func nestNode(withId draggedId: UUID, underNodeId parentNodeId: UUID, in nodes: inout [StartupSequenceNode]) {
        guard draggedId != parentNodeId,
              let sourcePath = path(to: draggedId, in: nodes),
              let processPath = path(to: parentNodeId, in: nodes) else { return }
        nestNode(from: sourcePath, under: processPath, in: &nodes)
    }

    /// Nests a process definition under another by process id (creates nodes if missing).
    /// Used when attaching from flat lists (e.g. Other commands) that are not sequence rows.
    static func nestProcessDefinition(
        _ childProcessId: UUID,
        underParentProcessId parentProcessId: UUID,
        in nodes: inout [StartupSequenceNode]
    ) {
        guard childProcessId != parentProcessId else { return }

        // Refuse nesting a process under one of its own descendants.
        if let childNode = nodeForProcessId(childProcessId, in: nodes),
           nodeForProcessId(parentProcessId, in: childNode.children) != nil {
            return
        }

        if nodeForProcessId(parentProcessId, in: nodes) == nil {
            nodes.append(StartupSequenceNode(kind: .process(parentProcessId)))
        }

        removeProcess(childProcessId, from: &nodes)

        guard let parentPath = pathToProcessId(parentProcessId, in: nodes) else { return }
        updateNode(at: parentPath, in: &nodes) { node in
            node.children.append(StartupSequenceNode(kind: .process(childProcessId)))
        }
    }

    /// Path to the sequence node wrapping a process definition id.
    /// The process a nested step is attached under, if any.
    static func parentProcessId(of processId: UUID, in nodes: [StartupSequenceNode]) -> UUID? {
        guard let path = pathToProcessId(processId, in: nodes) else { return nil }
        return parentProcessNodeId(for: path, in: nodes)
    }

    static func pathToProcessId(_ processId: UUID, in nodes: [StartupSequenceNode], currentPath: [Int] = []) -> [Int]? {
        for (index, node) in nodes.enumerated() {
            let nodePath = currentPath + [index]
            if case .process(let id) = node.kind, id == processId {
                return nodePath
            }
            if let found = pathToProcessId(processId, in: node.children, currentPath: nodePath) {
                return found
            }
        }
        return nil
    }

    static func outdentNode(withId nodeId: UUID, in nodes: inout [StartupSequenceNode]) {
        guard let path = path(to: nodeId, in: nodes) else { return }
        outdentNode(at: path, in: &nodes)
    }

    /// Moves a nested process definition to the root level (after its former parent).
    static func outdentProcessDefinition(_ processId: UUID, in nodes: inout [StartupSequenceNode]) {
        guard let path = pathToProcessId(processId, in: nodes), path.count >= 2 else { return }
        guard let extracted = extractNode(at: path, from: &nodes) else { return }
        let grandparentPath = Array(path.dropLast(2))
        let insertIndex = path[path.count - 2] + 1
        insert(extracted, atIndex: insertIndex, pathToParent: grandparentPath, into: &nodes)
    }

    static func insertPause(afterNodeId nodeId: UUID, seconds: Int = 3, in nodes: inout [StartupSequenceNode]) {
        guard let path = path(to: nodeId, in: nodes) else { return }
        let parentPath = Array(path.dropLast())
        let insertIndex = (path.last ?? 0) + 1
        insert(StartupSequenceNode(kind: .delay(seconds: seconds)), atIndex: insertIndex, pathToParent: parentPath, into: &nodes)
    }

    static func appendPause(seconds: Int = 3, to nodes: inout [StartupSequenceNode]) {
        insert(StartupSequenceNode(kind: .delay(seconds: seconds)), atIndex: nodes.count, pathToParent: [], into: &nodes)
    }

    static func removeNode(withId nodeId: UUID, from nodes: inout [StartupSequenceNode]) {
        guard let path = path(to: nodeId, in: nodes) else { return }
        removeNode(at: path, from: &nodes)
    }

    static func parentProcessNodeId(for path: [Int], in nodes: [StartupSequenceNode]) -> UUID? {
        guard path.count >= 2 else { return nil }
        var parentPath = Array(path.dropLast())
        while !parentPath.isEmpty {
            if let node = node(at: parentPath, in: nodes), case .process(let id) = node.kind {
                return id
            }
            parentPath = Array(parentPath.dropLast())
        }
        return nil
    }

    private static func extractNode(at path: [Int], from nodes: inout [StartupSequenceNode]) -> StartupSequenceNode? {
        guard let first = path.first, first >= 0, first < nodes.count else { return nil }
        if path.count == 1 {
            return nodes.remove(at: first)
        }
        return extractNode(at: Array(path.dropFirst()), from: &nodes[first].children)
    }
}
