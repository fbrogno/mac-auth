import CoreGraphics
import Foundation

/// Rules of the quick access panel (Spotlight-like code finder). Pure logic, tested; the views only draw.
public enum QuickAccess {
    /// The panel never lists more than this many rows (⌘1–⌘9 address them).
    public static let maxRows = 9
    /// A TOTP code with this many seconds left or fewer counts as "expiring": red, next code shown small.
    /// Same threshold as the cards of the main window.
    public static let expiringSeconds = 5
    public static let panelWidth: CGFloat = 560

    public static func isExpiring(kind: OTPKind, remaining: Int) -> Bool {
        kind == .totp && remaining <= expiringSeconds
    }

    // MARK: Rows

    /// The order of the main window: favourites, then the custom order, then issuer, name, id (deterministic).
    public static func standardOrder(_ a: Account, _ b: Account) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return restOrder(a, b)
    }

    private static func restOrder(_ a: Account, _ b: Account) -> Bool {
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        let issuer = a.issuer.localizedCaseInsensitiveCompare(b.issuer)
        if issuer != .orderedSame { return issuer == .orderedAscending }
        let name = a.name.localizedCaseInsensitiveCompare(b.name)
        if name != .orderedSame { return name == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }

    /// Empty query: favourites first (in the standard order), then accounts used before (most recent first),
    /// then the rest in the standard order.
    static func emptyQueryOrder(_ a: Account, _ b: Account) -> Bool {
        func tier(_ x: Account) -> Int { x.pinned ? 0 : (x.lastUsedAt != nil ? 1 : 2) }
        let (ta, tb) = (tier(a), tier(b))
        if ta != tb { return ta < tb }
        if ta == 1, let da = a.lastUsedAt, let db = b.lastUsedAt, da != db { return da > db }
        return restOrder(a, b)
    }

    /// What the panel lists: with an empty (or blank) query the order above, otherwise the search of the main
    /// window (issuer, name, group, note; best hits first, ties in the standard order); at most `maxRows`.
    public static func rows(from accounts: [Account], query: String, groupName: (UUID?) -> String?) -> [Account] {
        let blank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ordered = blank ? accounts.sorted(by: emptyQueryOrder) : AccountSearch.filter(accounts.sorted(by: standardOrder), query: query, groupName: groupName)
        return Array(ordered.prefix(maxRows))
    }

    // MARK: Keys

    public enum Key: Equatable, Sendable {
        case returnKey
        case optionReturn
        /// ⌘1…⌘9 (1-based).
        case command(Int)
    }

    public enum CopyAction: Equatable, Sendable {
        /// The code shown now (TOTP: this period, HOTP: the stored counter).
        case current(UUID)
        /// TOTP only: the code of the next period.
        case next(UUID)
        /// HOTP: the main window's "copy next code and count on" (copies counter + 1 and persists it).
        case advancingHOTP(UUID)
    }

    /// What a key does for the given rows. nil = nothing happens (no row, index out of range, ⌥↵ on HOTP).
    public static func copyAction(for key: Key, rows: [Account], selected: Int?) -> CopyAction? {
        func action(_ account: Account) -> CopyAction {
            account.kind == .hotp ? .advancingHOTP(account.id) : .current(account.id)
        }
        switch key {
        case .returnKey:
            guard let selected, rows.indices.contains(selected) else { return nil }
            return action(rows[selected])
        case .optionReturn:
            guard let selected, rows.indices.contains(selected), rows[selected].kind == .totp else { return nil }
            return .next(rows[selected].id)
        case .command(let n):
            guard (1...maxRows).contains(n), rows.indices.contains(n - 1) else { return nil }
            return action(rows[n - 1])
        }
    }

    /// ↑ (-1) / ↓ (+1): clamped to the rows, no wrap-around. No rows = no selection; no selection starts at the top.
    public static func moveSelection(_ current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return 0 }
        return min(max(current + delta, 0), count - 1)
    }

    public enum EscapeOutcome: Equatable, Sendable { case clearQuery, close }

    /// esc clears the query if there is one, otherwise closes the panel.
    public static func escape(query: String) -> EscapeOutcome {
        query.isEmpty ? .close : .clearQuery
    }

    // MARK: State, unlock

    public enum Content: Equatable, Sendable {
        /// Account rows. Only for an unlocked vault.
        case list
        /// Lock state: no account data at all, only the unlock button.
        case locked
        /// Starting up or no vault yet: nothing to show, the main window is the place.
        case unavailable
    }

    public static func content(for phase: AppPhase) -> Content {
        switch phase {
        case .unlocked: .list
        case .locked: .locked
        case .loading, .firstRun: .unavailable
        }
    }

    public enum Trigger: Equatable, Sendable {
        /// The user's global shortcut.
        case shortcut
        /// The user clicked the menu bar item.
        case statusItem
        /// Anything else (never a reason for a Touch ID prompt).
        case programmatic
    }

    /// Opening is a user action only for the shortcut and the menu bar click; an unlock prompt by itself needs that
    /// and a lock state where a prompt makes sense (not after "cannot open", which needs the main window).
    public static func mayPromptUnlock(trigger: Trigger, phase: AppPhase, noticeAllowsPrompt: Bool) -> Bool {
        trigger != .programmatic && phase == .locked && noticeAllowsPrompt
    }

    // MARK: Geometry

    /// Top-left of the panel on a screen's visible frame (y grows upward, as in AppKit screen coordinates):
    /// centred horizontally, top edge in the upper third; never outside the frame.
    public static func panelTopLeft(in visible: CGRect, size: CGSize) -> CGPoint {
        let x = min(max(visible.midX - size.width / 2, visible.minX), max(visible.maxX - size.width, visible.minX))
        let top = visible.maxY - visible.height * 0.2
        return CGPoint(x: x, y: min(top, visible.maxY))
    }
}

/// The shortcut of the quick access, and the migration of the former "global shortcut shows the window" option.
public struct QuickAccessShortcut: Equatable, Sendable {
    public var enabled: Bool
    /// Virtual key code, -1 = none recorded.
    public var keyCode: Int
    /// `NSEvent.ModifierFlags` raw value (device-independent bits).
    public var modifiers: Int
    public var label: String

    public init(enabled: Bool, keyCode: Int, modifiers: Int, label: String) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    public static let commandBit = 1 << 20, optionBit = 1 << 19, controlBit = 1 << 18, shiftBit = 1 << 17

    /// At least one of ⌘ ⌥ ⌃, so normal typing never triggers it.
    public static func hasRequiredModifier(_ raw: Int) -> Bool {
        raw & (commandBit | optionBit | controlBit) != 0
    }

    /// The suggestion when the user switches the feature on without a recorded combination: ⌥Space (key code 49).
    public static let suggestion = QuickAccessShortcut(enabled: true, keyCode: 49, modifiers: optionBit, label: "⌥Space")

    /// What the former preferences held (nil = key absent).
    public struct Legacy: Equatable, Sendable {
        public var enabled: Bool?
        public var keyCode: Int?
        public var modifiers: Int?
        public var label: String?
        public init(enabled: Bool? = nil, keyCode: Int? = nil, modifiers: Int? = nil, label: String? = nil) {
            self.enabled = enabled
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.label = label
        }
        public var isEmpty: Bool { enabled == nil && keyCode == nil && modifiers == nil && label == nil }
    }

    /// An enabled former shortcut with a usable combination becomes the (enabled) quick access shortcut with the
    /// same keys. Anything else migrates nothing (the feature stays off). Settings that already exist win.
    public static func migrate(legacy: Legacy, alreadyStored: Bool) -> QuickAccessShortcut? {
        guard !alreadyStored, legacy.enabled == true,
              let code = legacy.keyCode, code >= 0,
              let modifiers = legacy.modifiers, hasRequiredModifier(modifiers) else { return nil }
        return QuickAccessShortcut(enabled: true, keyCode: code, modifiers: modifiers, label: legacy.label ?? "")
    }
}
