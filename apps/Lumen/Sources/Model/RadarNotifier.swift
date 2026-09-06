import Foundation
import UserNotifications

/// Posts a Notification Center alert when the radar finds something.
///
/// Local notifications need permission, and an ad-hoc signed build does not
/// always get it — so this is deliberately best-effort. The in-app badge is
/// what the feature rests on; this is the nicety on top, and every failure is
/// swallowed rather than surfaced.
enum RadarNotifier {
    /// Asked for once, the first time a subscription is checked.
    static func requestPermissionIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
