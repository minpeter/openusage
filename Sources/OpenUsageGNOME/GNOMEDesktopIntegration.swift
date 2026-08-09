import Foundation
import OpenUsageLinuxCore

final class GNOMEDesktopIntegration: @unchecked Sendable {
    private let shortcuts: XDGGlobalShortcutsService
    private let tray: StatusNotifierItemService
    private let notifications: FreedesktopNotificationService

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
        notifications = FreedesktopNotificationService(dbus: adapter)
    }

    func start() async {
        do {
            try await shortcuts.start()
        } catch {
            NSLog("OpenUsage: global shortcut unavailable: \(error.localizedDescription)")
        }
        do {
            try await tray.start()
        } catch {
            NSLog("OpenUsage: tray unavailable: \(error.localizedDescription)")
        }
    }

    func stop() async {
        await shortcuts.stop()
        await tray.stop()
    }

    func postRefresh(_ snapshots: [ProviderUsageSnapshot]) async {
        let failures = snapshots.count { $0.errorMessage != nil }
        guard failures > 0 else { return }
        let body = "\(failures) of \(snapshots.count) provider accounts need attention."
        do {
            _ = try await notifications.post(
                LinuxNotification(title: "Provider Issues", body: body, urgency: 1)
            )
        } catch {
            NSLog("OpenUsage: notification unavailable: \(error.localizedDescription)")
        }
    }
}
