import Foundation
import IOKit.pwr_mgt
import Observation

/// Keeps the display from sleeping, like `caffeinate -d` or Amphetamine: holds an IOKit
/// "prevent idle display sleep" assertion, for a set time or until turned off.
/// macOS drops the assertion by itself when the app quits.
@MainActor
@Observable
final class KeepAwakeService {
    static let shared = KeepAwakeService()

    /// When the assertion ends; nil while active means "until turned off".
    private(set) var endDate: Date?
    private(set) var isActive = false

    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var timer: Timer?

    private init() {}

    /// Starts (or restarts) keeping the display awake. `duration` nil means until turned off.
    func start(for duration: TimeInterval?) {
        if !isActive {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Laradeck: keep display awake" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else { return }
            assertionID = id
            isActive = true
        }

        timer?.invalidate()
        timer = nil
        guard let duration else {
            endDate = nil
            return
        }
        endDate = Date().addingTimeInterval(duration)
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            Task { @MainActor in KeepAwakeService.shared.stop() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isActive {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
        endDate = nil
    }

    /// Seconds left, or nil when inactive or with no end.
    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard isActive, let endDate else { return nil }
        return max(0, endDate.timeIntervalSince(now))
    }

    /// "1:05:09" / "14:32" countdown.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
