import Foundation
import UserNotifications

/// Posts a Notification Center alert when the radar finds something.
///
/// Local notifications need permission, and an ad-hoc signed build does not
/// get it: macOS will not register a bundle with no Team ID, so the
/// authorization request fails and nothing is ever delivered. Measured rather
/// than assumed — after many launches this app is absent from the ninety-nine
/// entries in `com.apple.ncprefs`.
///
/// The in-app badge is therefore what the feature actually rests on. This is
/// the nicety on top, and it now *reports* when it is unavailable instead of
/// swallowing the reason, so the radar does not appear to be watching through
/// a channel that has never worked.
enum RadarNotifier {
    /// Why alerts are unavailable, or nil when they work.
    ///
    /// Read by Settings so the state is visible rather than inferred from
    /// never seeing one.
    nonisolated(unsafe) private(set) static var unavailableReason: String?

    /// Asked for once, the first time a subscription is checked.
    static func requestPermissionIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else {
            unavailableReason = "Lumen is running without a bundle identifier."
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    unavailableReason = error.localizedDescription
                } else if !granted {
                    unavailableReason = "Notifications are turned off for Lumen."
                } else {
                    unavailableReason = nil
                }
            }
    }

    /// Whether the system will actually deliver an alert.
    ///
    /// Nil outside an app bundle. `UNUserNotificationCenter.current()` traps
    /// when there is no bundle to attribute the notification to, which is the
    /// case for the verify harness — a bare executable, not an app.
    static func status() async -> UNAuthorizationStatus? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    static func announce(_ findings: [RadarResult]) {
        guard Bundle.main.bundleIdentifier != nil, !findings.isEmpty else { return }
        let centre = UNUserNotificationCenter.current()

        centre.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            let total = findings.reduce(0) { $0 + $1.newMatches }
            if findings.count == 1, let only = findings.first {
                content.title = "\(only.newMatches) new in \(only.label)"
            } else {
                content.title = "\(total) new wallpapers"
                content.subtitle = findings.map(\.label).joined(separator: ", ")
            }
            content.body = "Open Lumen to see them."
            content.sound = .default

            // nil trigger delivers immediately.
            centre.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content,
                                             trigger: nil))
        }
    }
}
