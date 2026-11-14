import AppKit

/// Lock triggers from the system: sleep, screen lock, fast user switching.
@MainActor
final class SystemLockObserver {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(onLock: @escaping @MainActor () -> Void, onReturn: @escaping @MainActor () -> Void) {
        func add(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
            tokens.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        add(workspace, NSWorkspace.willSleepNotification, onLock)
        add(workspace, NSWorkspace.screensDidSleepNotification, onLock)
        add(workspace, NSWorkspace.sessionDidResignActiveNotification, onLock)
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), onLock)
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), onReturn)
        add(workspace, NSWorkspace.sessionDidBecomeActiveNotification, onReturn)
        add(NotificationCenter.default, NSApplication.didBecomeActiveNotification, onReturn)
    }

    deinit {
        for entry in tokens { entry.center.removeObserver(entry.token) }
    }
}

/// Tracks the last user input (for auto-lock) and whether ⌘ is held (for the number badges on cards).
@MainActor @Observable
final class InputState {
    var commandHeld = false
    @ObservationIgnored var lastActivity = Date()
    @ObservationIgnored private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.lastActivity = Date()
                if event.type == .flagsChanged {
                    let held = event.modifierFlags.contains(.command)
                    if self?.commandHeld != held { self?.commandHeld = held }
                }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        commandHeld = false
    }
}
