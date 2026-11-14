import AppKit

/// Copies codes as concealed text and clears them after a delay, but only if nobody copied something else since.
@MainActor
final class ClipboardService {
    static let shared = ClipboardService()
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private var clearWork: DispatchWorkItem?
    private var changeCount: Int?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearIfUnchanged() }
        }
    }

    /// Puts `code` on the general pasteboard. `clearAfter` in seconds; 0 or less keeps it.
    func copy(_ code: String, clearAfter seconds: Int) {
        let pasteboard = NSPasteboard.general
        // Keep the code off Universal Clipboard / Handoff: it stays on this Mac.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.declareTypes([.string, Self.concealedType], owner: nil)
        pasteboard.setString(code, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
        changeCount = pasteboard.changeCount
        clearWork?.cancel()
        clearWork = nil
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.clearIfUnchanged() }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func clearIfUnchanged() {
        clearWork?.cancel()
        clearWork = nil
        guard let changeCount else { return }
        self.changeCount = nil
        if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
    }
}
