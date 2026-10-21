import SwiftUI

/// Compact summary shown under a process row — "Starts after …" / "Required by …".
struct ProcessDependencySummaryView: View {
    let project: Project
    let definition: ProcessDefinition
    let statusProvider: (UUID) -> ProcessStatus

    private var dependencyEntries: [(dependency: ProcessDependency, process: ProcessDefinition)] {
        project.dependencyEntries(of: definition)
    }

    private var dependents: [ProcessDefinition] {
        project.dependents(of: definition)
    }

    private var unmetDependencies: [ProcessDefinition] {
        dependencyEntries.map(\.process).filter { statusProvider($0.id) != .running }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !dependencyEntries.isEmpty {
                dependencyLine(
                    icon: "arrow.turn.down.right",
                    prefix: "Starts after",
                    labels: dependencyEntries.map(dependencyLabel),
                    highlight: !unmetDependencies.isEmpty
                )
            }
            if !dependents.isEmpty {
                dependencyLine(
                    icon: "link",
                    prefix: "Required by",
                    labels: dependents.map(\.name),
                    highlight: false
                )
            }
        }
    }

    private func dependencyLabel(_ entry: (dependency: ProcessDependency, process: ProcessDefinition)) -> String {
        if entry.dependency.delaySeconds > 0 {
            return "\(entry.process.name) (+\(entry.dependency.delaySeconds)s)"
        }
        return entry.process.name
    }

    @ViewBuilder
    private func dependencyLine(icon: String, prefix: String, labels: [String], highlight: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(highlight ? Color.orange : Color.secondary)
            Text("\(prefix):")
                .foregroundStyle(highlight ? Color.orange : Color.secondary)
            Text(labels.joined(separator: ", "))
                .fontWeight(.medium)
                .foregroundStyle(highlight ? Color.orange : Color.primary.opacity(0.75))
                .lineLimit(2)
        }
        .font(.caption2)
    }
}

/// Horizontal chain: [Web Server +3s] → [Vite] — used in the process editor preview.
struct ProcessDependencyChainView: View {
    let prerequisites: [(dependency: ProcessDependency, process: ProcessDefinition)]
    let targetName: String
    var statusProvider: ((UUID) -> ProcessStatus)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(prerequisites.enumerated()), id: \.element.process.id) { index, entry in
                    if index > 0 {
                        chainArrow(delaySeconds: nil)
                    }
                    processChip(entry)
                }

                if !prerequisites.isEmpty {
                    chainArrow(delaySeconds: nil)
                }
                targetChip
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chainArrow(delaySeconds: Int?) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
            if let delaySeconds, delaySeconds > 0 {
                Text("+\(delaySeconds)s")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func processChip(_ entry: (dependency: ProcessDependency, process: ProcessDefinition)) -> some View {
        HStack(spacing: 5) {
            if let statusProvider {
                StatusDotView(color: statusProvider(entry.process.id).color)
                    .scaleEffect(0.85)
            }
            Text(entry.process.name)
                .lineLimit(1)
            if entry.dependency.delaySeconds > 0 {
                Text("+\(entry.dependency.delaySeconds)s")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var targetChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "flag.checkered")
                .font(.caption2)
            Text(targetName)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

/// "Startup order" picker inside CustomProcessSheet.
struct ProcessDependencyEditorSection: View {
    @Binding var dependsOn: [ProcessDependency]
    let candidates: [ProcessDefinition]
    let project: Project
    let processName: String
    var statusProvider: ((UUID) -> ProcessStatus)?

    private var selectedEntries: [(dependency: ProcessDependency, process: ProcessDefinition)] {
        dependsOn.compactMap { entry in
            candidates.first { $0.id == entry.processId }.map { (entry, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick services that must be running before this one starts. Optionally wait a few seconds after each one comes up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !selectedEntries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Startup order")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ProcessDependencyChainView(
                        prerequisites: selectedEntries,
                        targetName: processName.trimmingCharacters(in: .whitespaces).isEmpty ? "This process" : processName,
                        statusProvider: statusProvider
                    )
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }

            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: selectionBinding(for: candidate.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                            Text(project.destinationLabel(for: candidate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    if isSelected(candidate.id) {
                        HStack(spacing: 8) {
                            Text("Wait")
                                .foregroundStyle(.secondary)
                            TextField("0", value: delayBinding(for: candidate.id), format: .number)
                                .frame(width: 48)
                                .multilineTextAlignment(.trailing)
                            Text("sec after it starts")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.leading, 20)
                    }
                }
            }

            if candidates.isEmpty {
                Text("Add other long-running processes first — only services can be prerequisites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isSelected(_ id: UUID) -> Bool {
        dependsOn.contains { $0.processId == id }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { isSelected(id) },
            set: { isOn in
                if isOn {
                    guard !isSelected(id) else { return }
                    dependsOn.append(ProcessDependency(processId: id))
                } else {
                    dependsOn.removeAll { $0.processId == id }
                }
            }
        )
    }

    private func delayBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: { dependsOn.first { $0.processId == id }?.delaySeconds ?? 0 },
            set: { newValue in
                guard let index = dependsOn.firstIndex(where: { $0.processId == id }) else { return }
                dependsOn[index].delaySeconds = max(0, newValue)
            }
        )
    }
}
