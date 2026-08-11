import Foundation
import OpenUsageLinuxCore

final class GNOMEDesktopIntegration: @unchecked Sendable {
    private let shortcuts: XDGGlobalShortcutsService
    private let tray: StatusNotifierItemService
    private let notificationPipeline: GNOMENotificationPipeline

    init(presentWindow: @escaping @Sendable () async -> Void) throws {
        let adapter = try GIODesktopDBusAdapter()
        shortcuts = XDGGlobalShortcutsService(
            dbus: adapter,
            presentWindow: presentWindow
        )
        tray = StatusNotifierItemService(
            dbus: adapter,
            presentWindow: presentWindow
        )
        let notifications = FreedesktopNotificationService(dbus: adapter)
        let thresholdNotifications = UsageThresholdNotificationCoordinator()
        notificationPipeline = GNOMENotificationPipeline { state in
            await deliverNotifications(
                state,
                notifications: notifications,
                thresholds: thresholdNotifications
            )
        }
    }

    func start() async {
        do {
            try await shortcuts.start()
        } catch {
            GNOMEAppLog.warning("Global shortcut unavailable: \(error.localizedDescription)")
        }
        do {
            try await tray.start()
        } catch {
            GNOMEAppLog.warning("Tray unavailable: \(error.localizedDescription)")
        }
    }

    func stop() async {
        await shortcuts.stop()
        await tray.stop()
    }

    func updateUsage(
        _ configuration: StatusNotifierItemConfiguration,
        revision: UInt64
    ) async {
        do {
            try await tray.update(configuration: configuration, revision: revision)
        } catch {
            GNOMEAppLog.warning("Tray update unavailable: \(error.localizedDescription)")
        }
    }

    func postRefresh(_ state: GNOMENotificationState) async {
        await notificationPipeline.submit(state)
    }
}

private func deliverNotifications(
    _ state: GNOMENotificationState,
    notifications: FreedesktopNotificationService,
    thresholds: UsageThresholdNotificationCoordinator
) async {
    let snapshots = state.snapshots
    let failures = snapshots.count { $0.errorMessage != nil }
    if failures > 0 {
        let body = "\(failures) of \(snapshots.count) provider accounts need attention."
        do {
            _ = try await notifications.post(
                LinuxNotification(
                    title: "Provider Issues",
                    body: body,
                    urgency: 1
                )
            )
        } catch {
            GNOMEAppLog.warning(
                "Notification unavailable: \(error.localizedDescription)"
            )
        }
    }

    let events = await thresholds.events(
        snapshots: snapshots.filter { $0.errorMessage == nil },
        toggles: state.toggles
    )
    for event in events {
        do {
            _ = try await notifications.post(LinuxNotification(
                title: event.milestone.title,
                body: "\(event.subtitle)\n\(event.milestone.body)",
                urgency: event.milestone == .willRunOut ? 2 : 1
            ))
            await thresholds.markDelivered(event)
        } catch {
            GNOMEAppLog.warning(
                "Threshold notification unavailable: \(error.localizedDescription)"
            )
        }
    }
}
