import SwiftUI

/// Toolbar block next to the environment status: keeps the display from sleeping for a
/// preset time (15 min, 30 min, 1 h, 2 h), a custom time, or until turned off.
struct KeepAwakeStatusView: View {
    @State private var showingOptions = false
    @AppStorage("keepAwakeCustomMinutes") private var customMinutes = 45

    private var service: KeepAwakeService { KeepAwakeService.shared }

    private static let presets: [(String, TimeInterval)] = [
        ("15 min", 15 * 60), ("30 min", 30 * 60), ("1 hour", 3600), ("2 hours", 2 * 3600),
    ]

    var body: some View {
        Button {
            showingOptions.toggle()
        } label: {
            HStack(spacing: 5) {
                StatusDotView(color: service.isActive ? .green : .gray, size: 7)
                Image(systemName: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                label
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(service.isActive ? "Display kept awake. Click to change or stop." : "Keep the display awake")
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            options
        }
    }

    /// Countdown while timed, "Awake" when indefinite, "Keep awake" when off.
    @ViewBuilder private var label: some View {
        if service.isActive, service.endDate != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(KeepAwakeService.format(service.remaining(at: context.date) ?? 0))
                    .monospacedDigit()
            }
        } else {
            Text(service.isActive ? "Awake" : "Keep awake")
        }
    }

    // MARK: Popover

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Keep Display Awake").font(.headline)
                StatusDotView(color: service.isActive ? .green : .gray, size: 7)
            }
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(Self.presets, id: \.0) { preset in
                    Button(preset.0) { start(preset.1) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)

            Button("Until I turn it off") { start(nil) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

            Divider()

            HStack(spacing: 8) {
                Text("Custom")
                Spacer(minLength: 0)
                TextField("Minutes", value: $customMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .onSubmit(startCustom)
                Stepper("Minutes", value: $customMinutes, in: 1...1440, step: 5)
                    .labelsHidden()
                Text("min").foregroundStyle(.secondary)
                Button("Start", action: startCustom)
                    .buttonStyle(.borderedProminent)
                    .disabled(customMinutes < 1)
            }
            .controlSize(.small)

            if service.isActive {
                Button(role: .destructive) {
                    service.stop()
                } label: {
                    Label("Let the display sleep", systemImage: "moon.zzz")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var statusText: String {
        guard service.isActive else { return "The display sleeps as set in System Settings." }
        guard let end = service.endDate else { return "The display stays on until you turn this off." }
        return "The display stays on until \(end.formatted(date: .omitted, time: .shortened))."
    }

    private func startCustom() {
        customMinutes = min(max(customMinutes, 1), 1440)
        start(TimeInterval(customMinutes * 60))
    }

    private func start(_ duration: TimeInterval?) {
        service.start(for: duration)
        showingOptions = false
    }
}
