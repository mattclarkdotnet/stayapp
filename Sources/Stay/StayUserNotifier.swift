import Foundation
import OSLog
@preconcurrency import UserNotifications

protocol StayUserNotifying {
    func notifySeparateSpacesSuspended()
}

// Design goal: best-effort user feedback without coupling launch policy to
// notification-center authorization state.
final class StayUserNotificationCenter: StayUserNotifying {
    private let logger = Logger(subsystem: "com.stay.app", category: "UserNotifications")
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notifySeparateSpacesSuspended() {
        center.getNotificationSettings { [center, logger] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.enqueuePauseNotification(using: center, logger: logger)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        logger.error(
                            "Notification authorization request failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }

                    guard granted else {
                        logger.info(
                            "Notification authorization not granted; relying on status item only"
                        )
                        return
                    }

                    Self.enqueuePauseNotification(using: center, logger: logger)
                }
            case .denied:
                logger.info("Notification authorization denied; relying on status item only")
            @unknown default:
                logger.info("Unknown notification authorization state; skipping notification")
            }
        }
    }

    private static func enqueuePauseNotification(
        using center: UNUserNotificationCenter,
        logger: Logger
    ) {
        let content = UNMutableNotificationContent()
        content.title = SeparateSpacesSuspensionPolicy.suspendedNotificationTitle
        content.body = SeparateSpacesSuspensionPolicy.suspendedNotificationBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.stay.app.notifications.separate-spaces-paused",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                logger.error(
                    "Failed to enqueue separate-spaces notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
