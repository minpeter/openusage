import CAdwaita

private final class GTKClosureBox: @unchecked Sendable {
    let closure: @MainActor @Sendable () -> Void

    init(_ closure: @escaping @MainActor @Sendable () -> Void) {
        self.closure = closure
    }
}

nonisolated func scheduleOnGTK(_ closure: @escaping @MainActor @Sendable () -> Void) {
    let pointer = Unmanaged.passRetained(GTKClosureBox(closure)).toOpaque()
    g_idle_add_full(
        G_PRIORITY_DEFAULT_IDLE,
        { userData -> gboolean in
            guard let userData else { return 0 }
            let box = Unmanaged<GTKClosureBox>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                box.closure()
            }
            return 0
        },
        pointer,
        { userData in
            guard let userData else { return }
            Unmanaged<GTKClosureBox>.fromOpaque(userData).release()
        }
    )
}
