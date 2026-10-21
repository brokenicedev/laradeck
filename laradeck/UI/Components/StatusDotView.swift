import SwiftUI

extension ProcessStatus {
    var color: Color {
        switch self {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

extension DockerServiceStatus {
    var color: Color {
        if isUnhealthy || isDead || exitedWithError { return .red }
        if isRunning { return .green }
        if isRestarting || isHealthCheckStarting { return .yellow }
        return .gray
    }
}

extension ProjectHealth {
    var color: Color {
        switch self {
        case .running: return .green
        case .attention: return .orange
        case .error: return .red
        case .other: return .blue
        case .stopped: return .gray
        }
    }
}

extension DockerDaemonState {
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .running: return .green
        case .stopped: return .red
        case .notInstalled: return .orange
        }
    }
}

struct StatusDotView: View {
    let color: Color
    var size: CGFloat = 8
    var pulsing: Bool = false
    /// A white ring around the dot — used where it needs to stand out (e.g. the sidebar).
    var showsBorder: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if showsBorder {
                    Circle().strokeBorder(.white, lineWidth: 1.5)
                }
            }
            .shadow(color: pulsing ? color.opacity(0.65) : .clear, radius: pulsing ? 3 : 0)
            .background {
                if pulsing {
                    StatusDotPulseEffect(color: color, size: size)
                }
            }
    }
}

/// Soft breathing glow + expanding ring for active status dots (e.g. running Other commands).
private struct StatusDotPulseEffect: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let breathe = (sin(seconds * 2.4) + 1) / 2
            let ping = seconds.truncatingRemainder(dividingBy: 1.5) / 1.5

            ZStack {
                Circle()
                    .stroke(color.opacity(0.5 * (1 - ping)), lineWidth: 1)
                    .frame(width: size, height: size)
                    .scaleEffect(1 + ping * 1.35)

                Circle()
                    .fill(color.opacity(0.12 + breathe * 0.22))
                    .frame(
                        width: size * (1.45 + breathe * 0.35),
                        height: size * (1.45 + breathe * 0.35)
                    )
                    .blur(radius: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}
