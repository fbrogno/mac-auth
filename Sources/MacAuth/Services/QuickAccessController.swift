import AppKit
import AuthCore
import Carbon.HIToolbox
import Observation
import SwiftUI

/// What the quick access panel shows and the user typed. One instance per opening; dropped when the panel closes.
@MainActor @Observable
final class QuickPanelState {
    var query = "" {
        // The row order is decided here (and when the panel opens), never because usage data changed.
        didSet { if query != oldValue { selectedIndex = 0; selectionExplicit = false; reloadRows() } }
    }
    var selectedIndex: Int? = 0
    /// The rows (ids) in the frozen order, once the list has been built.
    private(set) var rowIDs: [UUID] = []
    private(set) var rowsReady = false
    @ObservationIgnored private weak var model: AppModel?

    init(model: AppModel? = nil) { self.model = model }

    /// Builds the order for the current query from the current data (opening, unlock, query change).
    func reloadRows() {
        guard let model else { return }
        rowIDs = QuickAccess.rowIDs(from: model.accounts, query: query, groupName: { [model] in model.group($0)?.name })
        rowsReady = true
    }

    /// The rows to show and to act on: the frozen order with current data. Before the list was built (the single
    /// render between the unlock and `listAppeared`) the order is computed directly.
    func rows(in model: AppModel) -> [Account] {
        guard rowsReady else { return QuickAccess.rows(from: model.accounts, query: query, groupName: { [model] in model.group($0)?.name }) }
        return QuickAccess.resolve(rowIDs, in: model.accounts)
    }

    /// The list is on screen for the current lock generation: take the ticket (once) and freeze the order.
    /// Whatever way the vault got unlocked (this panel, the main window, a running prompt), copying then works.
    func listAppeared() {
        guard let model else { return }
        if listTicket == nil { listTicket = model.ticket }
        if !rowsReady { reloadRows() }
    }

    /// True once the user moved the selection with the arrow keys; the automatic first row does not reveal a hidden code.
    var selectionExplicit = false
    /// The row that was just copied ("Kopiert" confirmation).
    var copiedID: UUID?
    /// Phase and lock generation the list was built in. Every copy checks it still holds.
    @ObservationIgnored var listTicket: Ticket?
}

/// Borderless panel that takes key focus (typing) without activating MacAuth, so the app the user came from keeps
/// its place and gets the focus back when the panel closes.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Global shortcut, optional menu bar item and the panel itself. Owned by `AppModel`; it works on that model only,
/// so a demo model can never show a real vault and the other way round.
@MainActor
final class QuickAccessController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private let hotKey = HotKeyService()
    private var statusItem: NSStatusItem?
    private var panel: QuickPanel?
    private var state: QuickPanelState?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var closeTask: Task<Void, Never>?
    /// Counts openings; late results (unlock, confirmation timer) of an earlier opening are dropped.
    private var session = 0
    private var unlocking = false
    /// A click on the menu bar item first takes key status from the panel (which closes it); that click must not reopen it.
    private var lastResignClose = Date.distantPast

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isOpen: Bool { panel != nil }

    // MARK: Registration

    /// Registers or removes the shortcut and the menu bar item according to the settings. Sets
    /// `model.quickAccessError` in plain words when the shortcut cannot be registered.
    func apply() {
        model.quickAccessError = nil
        let settings = model.settings
        guard settings.quickAccessEnabled else {
            hotKey.unregister()
            removeStatusItem()
            close()
            return
        }
        if settings.quickAccessKeyCode < 0 {
            hotKey.unregister()
            model.quickAccessError = String(localized: "Nimm zuerst eine Tastenkombination auf.")
        } else {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(settings.quickAccessModifiers))
            switch hotKey.register(keyCode: UInt32(settings.quickAccessKeyCode), modifiers: flags, onPress: { [weak self] in self?.toggle(trigger: .shortcut) }) {
            case .success: break
            case .failure(.needsModifier):
                model.quickAccessError = String(localized: "Die Kombination braucht mindestens ⌘, ⌥ oder ⌃.")
            case .failure(.taken):
                model.quickAccessError = String(localized: "Diese Kombination ist in MacAuth schon belegt. Wähle eine andere.")
            case .failure(.other):
                model.quickAccessError = String(localized: "Die Tastenkombination konnte nicht angemeldet werden.")
            }
        }
        if settings.menuBarItem { installStatusItem() } else { removeStatusItem() }
    }

    func pauseShortcut() { hotKey.unregister() }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // Fixed, generic symbol and label: nothing about accounts ever appears in the menu bar item.
            let image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("MacAuth")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if panel == nil, Date().timeIntervalSince(lastResignClose) < 0.3 { return }
        toggle(trigger: .statusItem, anchor: sender)
    }

    // MARK: Open, close

    /// Shortcut pressed or menu bar item clicked: opens the panel, or closes it if it is open.
    func toggle(trigger: QuickAccess.Trigger, anchor: NSStatusBarButton? = nil) {
        if panel != nil { close(); return }
        open(trigger: trigger, anchor: anchor)
    }

    private func open(trigger: QuickAccess.Trigger, anchor: NSStatusBarButton?) {
        session += 1
        let state = QuickPanelState(model: model)
        self.state = state
        let me = ProcessInfo.processInfo.processIdentifier
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == me ? nil : $0 }

        let hosting = NSHostingView(rootView: QuickAccessView(model: model, state: state, controller: self))
        let fitted = hosting.fittingSize
        let size = CGSize(width: QuickAccess.panelWidth, height: max(fitted.height, 120))
        let panel = QuickPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        // Strict until the view says otherwise: follows the security setting (strict while locked), live.
        panel.sharingType = model.settings.protectScreen ? .none : .readOnly
        panel.delegate = self
        self.panel = panel

        place(panel, size: size, anchor: anchor)
        // Opening counts as activity for auto-lock, like touching the main window. Nothing keeps the vault open after that.
        model.input.lastActivity = Date()
        if model.phase == .unlocked { state.listAppeared() }
        installKeyMonitor()
        panel.orderFrontRegardless()
        panel.makeKey()

        if !model.isUnlocking,
           QuickAccess.mayPromptUnlock(trigger: trigger, phase: model.phase, noticeAllowsPrompt: model.noticeAllowsUnlockPrompt) {
            unlock()
        }
    }

    private func place(_ panel: NSPanel, size: CGSize, anchor: NSStatusBarButton?) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var topLeft = QuickAccess.panelTopLeft(in: visible, size: size)
        if let itemFrame = anchor?.window?.frame {
            let x = min(max(itemFrame.midX - size.width / 2, visible.minX + 8), max(visible.maxX - size.width - 8, visible.minX))
            topLeft = CGPoint(x: x, y: min(itemFrame.minY - 6, visible.maxY))
        }
        panel.setFrameTopLeftPoint(topLeft)
    }

    /// Closes at once and drops everything the panel held (query, selection, hosted view).
    func close() {
        guard let panel else { return }
        closeTask?.cancel()
        closeTask = nil
        session += 1
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        self.panel = nil
        state = nil
        unlocking = false
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentView = nil
        // The panel never activated MacAuth, so the previous app normally still has the focus. If something did
        // activate us meanwhile (the system authentication dialog), hand it back.
        if NSApp.isActive, let previous = previousApp, !previous.isTerminated { previous.activate() }
        previousApp = nil
    }

    /// The vault locked (auto-lock, sleep, screen lock, user switch, ⌘L): content gone, panel closed, nothing in flight completes.
    func vaultDidLock() { close() }

    func windowDidResignKey(_ notification: Notification) {
        guard panel != nil, !unlocking else { return }   // the system authentication dialog takes key status for a moment
        lastResignClose = Date()
        close()
    }

    /// Resizes with the content; the top edge stays where it is.
    func contentSizeChanged(_ size: CGSize) {
        guard let panel, size.height > 1 else { return }
        let frame = panel.frame
        let target = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        guard abs(frame.height - size.height) > 0.5 else { return }
        panel.setFrame(target, display: true, animate: false)
        panel.invalidateShadow()
    }

    // MARK: Actions

    /// The same unlock as the main window's button (`AppModel.unlock`): no second implementation, no shortcut around
    /// the recovery and pending-authentication rules. The list appears in this panel after a success.
    func unlock() {
        guard QuickAccess.content(for: model.phase) == .locked, !unlocking, !model.isUnlocking else { return }
        unlocking = true
        let current = session
        Task { [weak self] in
            guard let self else { return }
            await model.unlock()
            guard session == current, let panel else { return }
            unlocking = false
            if model.phase == .unlocked {
                state?.query = ""
                state?.reloadRows()
                state?.listAppeared()
            }
            panel.makeKey()
            if !panel.isKeyWindow { close() }
        }
    }

    func openMainWindow() {
        close()
        NSApp.unhide(nil)
        NSApp.activate()
        let window = NSApp.windows.first { $0.title == "MacAuth" && !($0 is NSPanel) }
            ?? NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Copies what `key` resolves to for the rows shown now.
    func copy(_ key: QuickAccess.Key) {
        guard let state, state.copiedID == nil, let ticket = state.listTicket, QuickAccess.content(for: model.phase) == .list else { return }
        let rows = state.rows(in: model)
        guard let action = QuickAccess.copyAction(for: key, rows: rows, selected: state.selectedIndex) else { return }
        guard model.copyFromQuickAccess(action, ticket: ticket) else { close(); return }   // stale list: never copy
        switch action {
        case .current(let id), .next(let id), .advancingHOTP(let id): state.copiedID = id
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            close()
            return
        }
        let current = session
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, session == current else { return }
            close()
        }
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// True for events the panel consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }
        // Interaction with the panel counts as activity exactly like interaction with the main window.
        model.input.lastActivity = Date()
        guard event.type == .keyDown, let state else { return false }
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }   // composing text (IME)

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let content = QuickAccess.content(for: model.phase)
        let code = Int(event.keyCode)

        if flags.contains(.command) {
            // The rules are `QuickAccess.commandOutcome` (tested): digits by key code, ⌘L locks, text commands go to the
            // search field, ⌘C only with a selection, everything else is swallowed (no command of the main window).
            let selected = ((panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
            switch QuickAccess.commandOutcome(keyCode: code, character: event.charactersIgnoringModifiers,
                                              modifiers: Int(event.modifierFlags.rawValue), textSelected: selected) {
            case .copyRow(let n): copy(.command(n))
            case .close: close()
            case .lock: if model.phase == .unlocked, !model.isDemo { model.lock() }
            case .passToField: return false
            case .swallow: break
            }
            return true
        }

        switch code {
        case kVK_Escape:
            if content == .list, QuickAccess.escape(query: state.query) == .clearQuery { state.query = "" } else { close() }
        case kVK_DownArrow where content == .list:
            move(+1, state: state)
        case kVK_UpArrow where content == .list:
            move(-1, state: state)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            switch content {
            case .list: copy(flags == .option ? .optionReturn : .returnKey)
            case .locked: if model.lockNotice == .cannotOpen { openMainWindow() } else { unlock() }
            case .unavailable: openMainWindow()
            }
        default:
            return false
        }
        return true
    }

    private func move(_ delta: Int, state: QuickPanelState) {
        let count = state.rows(in: model).count
        state.selectedIndex = QuickAccess.moveSelection(state.selectedIndex, delta: delta, count: count)
        state.selectionExplicit = true
    }
}
