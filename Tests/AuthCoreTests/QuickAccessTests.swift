import Foundation
import Testing
@testable import AuthCore

@Suite struct QuickAccessTests {
    private func account(_ issuer: String, name: String = "a@example.org", index: Int = 0, pinned: Bool = false,
                         used: TimeInterval? = nil, kind: OTPKind = .totp, note: String = "") -> Account {
        Account(issuer: issuer, name: name, secret: Data([1, 2, 3, 4]), kind: kind, pinned: pinned, sortIndex: index,
                lastUsedAt: used.map { Date(timeIntervalSince1970: $0) }, note: note)
    }

    private func issuers(_ rows: [Account]) -> [String] { rows.map(\.issuer) }
    private func list(_ accounts: [Account], _ query: String = "") -> [Account] {
        QuickAccess.rows(from: accounts, query: query, groupName: { _ in nil })
    }

    // MARK: Order for an empty query

    @Test func emptyQueryPutsFavouritesThenRecentThenRest() {
        let accounts = [
            account("Rest B", index: 5), account("Recent Old", index: 9, used: 100), account("Fav", index: 7, pinned: true),
            account("Recent New", index: 8, used: 900), account("Rest A", index: 2),
        ]
        #expect(issuers(list(accounts)) == ["Fav", "Recent New", "Recent Old", "Rest A", "Rest B"])
    }

    @Test func favouritesKeepStandardOrderEvenIfUsedLater() {
        let accounts = [account("Fav 2", index: 2, pinned: true, used: 900), account("Fav 1", index: 1, pinned: true, used: 10)]
        #expect(issuers(list(accounts)) == ["Fav 1", "Fav 2"])
    }

    @Test func tiesFallBackToIndexIssuerNameThenId() {
        let used: TimeInterval = 500
        let same1 = account("Same", name: "b", index: 3, used: used), same2 = account("Same", name: "a", index: 3, used: used)
        let other = account("Alpha", index: 3, used: used)
        #expect(list([same1, same2, other]).map { "\($0.issuer)/\($0.name)" } == ["Alpha/a@example.org", "Same/a", "Same/b"])
        var x = account("X", index: 1), y = account("X", index: 1)
        x.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        y.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        #expect(list([x, y]).map(\.id) == [y.id, x.id])
        // Same time: the standard order decides, not the input order.
        let t1 = account("B", index: 2, used: used), t2 = account("A", index: 1, used: used)
        #expect(issuers(list([t1, t2])) == ["A", "B"])
    }

    @Test func blankQueryCountsAsEmpty() {
        let accounts = [account("Z", index: 1), account("Used", index: 2, used: 5)]
        #expect(issuers(list(accounts, "   ")) == ["Used", "Z"])
    }

    @Test func neverMoreThanNineRows() {
        let many = (0..<25).map { account("A\($0)", index: $0) }
        #expect(list(many).count == QuickAccess.maxRows)
        #expect(list(many, "A").count == QuickAccess.maxRows)
        #expect(list(Array(many.prefix(4))).count == 4)
        #expect(list([]).isEmpty)
    }

    @Test func queryUsesTheSearchOfTheMainWindow() {
        let accounts = [
            account("Mail", name: "x", index: 1), account("Cloud", name: "mail@example.org", index: 2),
            account("Bank", name: "y", index: 3, note: "mail-Adresse"), account("Other", index: 4),
        ]
        // prefix of issuer first, then name contains, then note
        #expect(issuers(list(accounts, "mail")) == ["Mail", "Cloud", "Bank"])
        let group = UUID()
        var grouped = account("Git", index: 9)
        grouped.groupID = group
        let result = QuickAccess.rows(from: accounts + [grouped], query: "firma", groupName: { $0 == group ? "Firma" : nil })
        #expect(issuers(result) == ["Git"])
        // equal hits keep the standard order (favourite first)
        let fav = account("Aaa", index: 8, pinned: true), plain = account("Aab", index: 1)
        #expect(issuers(list([plain, fav], "aa")) == ["Aaa", "Aab"])
    }

    // MARK: Keys

    @Test func returnCopiesTheDisplayedCodeForTOTPAndHOTPWithoutAdvancing() {
        let totp = account("T"), hotp = account("H", kind: .hotp)
        let rows = [totp, hotp]
        #expect(QuickAccess.copyAction(for: .returnKey, rows: rows, selected: 0) == .current(totp.id))
        #expect(QuickAccess.copyAction(for: .returnKey, rows: rows, selected: 1) == .current(hotp.id))
    }

    @Test func optionReturnIsTheNextPeriodForTOTPAndCountsOnForHOTP() {
        let totp = account("T"), hotp = account("H", kind: .hotp)
        #expect(QuickAccess.copyAction(for: .optionReturn, rows: [totp, hotp], selected: 0) == .next(totp.id))
        #expect(QuickAccess.copyAction(for: .optionReturn, rows: [totp, hotp], selected: 1) == .advancingHOTP(hotp.id))
        #expect(QuickAccess.copyAction(for: .optionReturn, rows: [totp, hotp], selected: 2) == nil)
        #expect(QuickAccess.copyAction(for: .optionReturn, rows: [], selected: nil) == nil)
    }

    @Test func commandNumberAddressesRowsDirectly() {
        let rows = (0..<3).map { account("R\($0)", kind: $0 == 2 ? .hotp : .totp) }
        #expect(QuickAccess.copyAction(for: .command(1), rows: rows, selected: 2) == .current(rows[0].id))
        #expect(QuickAccess.copyAction(for: .command(3), rows: rows, selected: nil) == .current(rows[2].id))   // HOTP: shown code, no advance
        #expect(QuickAccess.copyAction(for: .command(4), rows: rows, selected: 0) == nil)
        #expect(QuickAccess.copyAction(for: .command(0), rows: rows, selected: 0) == nil)
        #expect(QuickAccess.copyAction(for: .command(10), rows: rows, selected: 0) == nil)
        #expect(QuickAccess.copyAction(for: .command(-1), rows: rows, selected: 0) == nil)
    }

    @Test func noRowOrBadSelectionDoesNothing() {
        let rows = [account("A")]
        #expect(QuickAccess.copyAction(for: .returnKey, rows: [], selected: 0) == nil)
        #expect(QuickAccess.copyAction(for: .returnKey, rows: rows, selected: nil) == nil)
        #expect(QuickAccess.copyAction(for: .returnKey, rows: rows, selected: 1) == nil)
        #expect(QuickAccess.copyAction(for: .returnKey, rows: rows, selected: -1) == nil)
        #expect(QuickAccess.copyAction(for: .optionReturn, rows: rows, selected: 5) == nil)
        #expect(QuickAccess.copyAction(for: .command(1), rows: [], selected: nil) == nil)
    }

    @Test func selectionMovesWithoutWrapping() {
        #expect(QuickAccess.moveSelection(0, delta: 1, count: 3) == 1)
        #expect(QuickAccess.moveSelection(2, delta: 1, count: 3) == 2)
        #expect(QuickAccess.moveSelection(0, delta: -1, count: 3) == 0)
        #expect(QuickAccess.moveSelection(nil, delta: 1, count: 3) == 0)
        #expect(QuickAccess.moveSelection(7, delta: -1, count: 3) == 0)
        #expect(QuickAccess.moveSelection(0, delta: 1, count: 0) == nil)
    }

    @Test func escapeClearsThenCloses() {
        #expect(QuickAccess.escape(query: "git") == .clearQuery)
        #expect(QuickAccess.escape(query: "") == .close)
    }

    // MARK: Expiring

    @Test func expiringThresholdMatchesTheCards() {
        #expect(QuickAccess.isExpiring(kind: .totp, remaining: 5))
        #expect(QuickAccess.isExpiring(kind: .totp, remaining: 1))
        #expect(!QuickAccess.isExpiring(kind: .totp, remaining: 6))
        #expect(!QuickAccess.isExpiring(kind: .hotp, remaining: 0))
        #expect(QuickAccess.expiringSeconds == 5)
    }

    // MARK: Lock state

    @Test func onlyAnUnlockedVaultShowsRows() {
        #expect(QuickAccess.content(for: .unlocked) == .list)
        #expect(QuickAccess.content(for: .locked) == .locked)
        #expect(QuickAccess.content(for: .loading) == .unavailable)
        #expect(QuickAccess.content(for: .firstRun) == .unavailable)
    }

    @Test func promptOnlyForUserTriggersWhileLocked() {
        #expect(QuickAccess.mayPromptUnlock(trigger: .shortcut, phase: .locked, noticeAllowsPrompt: true))
        #expect(QuickAccess.mayPromptUnlock(trigger: .statusItem, phase: .locked, noticeAllowsPrompt: true))
        #expect(!QuickAccess.mayPromptUnlock(trigger: .programmatic, phase: .locked, noticeAllowsPrompt: true))
        #expect(!QuickAccess.mayPromptUnlock(trigger: .shortcut, phase: .locked, noticeAllowsPrompt: false))
        #expect(!QuickAccess.mayPromptUnlock(trigger: .shortcut, phase: .unlocked, noticeAllowsPrompt: true))
        #expect(!QuickAccess.mayPromptUnlock(trigger: .shortcut, phase: .loading, noticeAllowsPrompt: true))
        #expect(!QuickAccess.mayPromptUnlock(trigger: .shortcut, phase: .firstRun, noticeAllowsPrompt: true))
    }

    // MARK: Geometry

    @Test func panelIsCentredInTheUpperThirdAndStaysOnScreen() {
        let screen = CGRect(x: 100, y: 50, width: 1600, height: 900)
        let size = CGSize(width: QuickAccess.panelWidth, height: 400)
        let p = QuickAccess.panelTopLeft(in: screen, size: size)
        #expect(p.x == screen.midX - size.width / 2)
        #expect(p.y <= screen.maxY && p.y >= screen.maxY - screen.height / 3)
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 800)
        let q = QuickAccess.panelTopLeft(in: narrow, size: size)
        #expect(q.x == 0)
    }

    // MARK: Migration of the former hotkey option

    @Test func enabledLegacyShortcutMovesOverWithTheSameKeys() {
        let legacy = QuickAccessShortcut.Legacy(enabled: true, keyCode: 46, modifiers: QuickAccessShortcut.controlBit | QuickAccessShortcut.optionBit, label: "⌃⌥M")
        let result = QuickAccessShortcut.migrate(legacy: legacy, alreadyStored: false)
        #expect(result == QuickAccessShortcut(enabled: true, keyCode: 46, modifiers: QuickAccessShortcut.controlBit | QuickAccessShortcut.optionBit, label: "⌃⌥M"))
    }

    @Test func nothingIsMigratedWhenDisabledUnusableOrAlreadyThere() {
        let ok = QuickAccessShortcut.Legacy(enabled: true, keyCode: 46, modifiers: QuickAccessShortcut.commandBit, label: "⌘M")
        #expect(QuickAccessShortcut.migrate(legacy: ok, alreadyStored: true) == nil)
        var off = ok; off.enabled = false
        #expect(QuickAccessShortcut.migrate(legacy: off, alreadyStored: false) == nil)
        var absent = ok; absent.enabled = nil
        #expect(QuickAccessShortcut.migrate(legacy: absent, alreadyStored: false) == nil)
        var noKey = ok; noKey.keyCode = -1
        #expect(QuickAccessShortcut.migrate(legacy: noKey, alreadyStored: false) == nil)
        var missingKey = ok; missingKey.keyCode = nil
        #expect(QuickAccessShortcut.migrate(legacy: missingKey, alreadyStored: false) == nil)
        var shiftOnly = ok; shiftOnly.modifiers = QuickAccessShortcut.shiftBit
        #expect(QuickAccessShortcut.migrate(legacy: shiftOnly, alreadyStored: false) == nil)
        #expect(QuickAccessShortcut.migrate(legacy: .init(), alreadyStored: false) == nil)
        #expect(QuickAccessShortcut.Legacy().isEmpty)
        // a missing label does not stop the migration
        var noLabel = ok; noLabel.label = nil
        #expect(QuickAccessShortcut.migrate(legacy: noLabel, alreadyStored: false)?.label == "")
    }

    @Test func suggestionIsControlOptionSpace() {
        let s = QuickAccessShortcut.suggestion
        #expect(s.keyCode == 49 && s.modifiers == QuickAccessShortcut.controlBit | QuickAccessShortcut.optionBit && s.label == "⌃⌥Space")
        #expect(QuickAccessShortcut.hasRequiredModifier(s.modifiers))
        #expect(!QuickAccessShortcut.hasRequiredModifier(0))
    }

    // MARK: Frozen order (U1)

    @Test func copyingDoesNotReorderTheOpenPanel() {
        var accounts = [account("A", index: 1), account("B", index: 2), account("C", index: 3, used: 100)]
        let ids = QuickAccess.rowIDs(from: accounts, query: "", groupName: { _ in nil })
        #expect(ids == [accounts[2].id, accounts[0].id, accounts[1].id])
        // B is copied: lastUsedAt changes, a fresh order would put B first.
        accounts[1].lastUsedAt = Date(timeIntervalSince1970: 900)
        #expect(issuers(list(accounts)) == ["B", "C", "A"])
        // The frozen ids keep their positions, with current data.
        let shown = QuickAccess.resolve(ids, in: accounts)
        #expect(issuers(shown) == ["C", "A", "B"])
        #expect(shown[2].lastUsedAt != nil)
        // The next opening computes again.
        #expect(QuickAccess.rowIDs(from: accounts, query: "", groupName: { _ in nil }) == [accounts[1].id, accounts[2].id, accounts[0].id])
    }

    @Test func frozenIDsDropDeletedAccountsAndKeepOrderForAQuery() {
        let accounts = [account("Mail", index: 1), account("Mailbox", index: 2)]
        let ids = QuickAccess.rowIDs(from: accounts, query: "mail", groupName: { _ in nil })
        #expect(QuickAccess.resolve(ids, in: [accounts[1]]).map(\.issuer) == ["Mailbox"])
        #expect(QuickAccess.resolve([], in: accounts).isEmpty)
        #expect(QuickAccess.resolve([UUID()], in: accounts).isEmpty)
    }

    // MARK: ⌘ commands (N5)

    private let cmd = QuickAccessShortcut.commandBit, shift = QuickAccessShortcut.shiftBit, opt = QuickAccessShortcut.optionBit

    private func outcome(_ key: Int, _ char: String?, _ mods: Int, selected: Bool = false) -> QuickAccess.CommandOutcome {
        QuickAccess.commandOutcome(keyCode: key, character: char, modifiers: mods, textSelected: selected)
    }

    @Test func commandDigitsAreResolvedByKeyCode() {
        // AZERTY: the number row types "&é\"'(§è!ç", charactersIgnoringModifiers is no digit, the key code still is.
        #expect(outcome(18, "&", cmd) == .copyRow(1))
        #expect(outcome(25, "ç", cmd) == .copyRow(9))
        #expect(outcome(83, "1", cmd) == .copyRow(1))
        #expect(outcome(29, "0", cmd) == .swallow)   // ⌘0 is no row
        let expected = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        for (code, n) in expected { #expect(QuickAccess.digit(forKeyCode: code) == n) }
        #expect(QuickAccess.digit(forKeyCode: 0) == nil)
        #expect(outcome(18, "1", cmd | shift) == .swallow)
        #expect(outcome(18, "1", cmd | opt) == .swallow)
    }

    @Test func commandLLocksAndCommandWCloses() {
        #expect(outcome(37, "l", cmd) == .lock)
        #expect(outcome(13, "w", cmd) == .close)
        #expect(outcome(37, "l", cmd | shift) == .swallow)
    }

    @Test func textCommandsGoToTheSearchField() {
        for (code, char) in [(0, "a"), (9, "v"), (7, "x"), (6, "z")] {
            #expect(outcome(code, char, cmd) == .passToField)
            #expect(outcome(code, char, cmd | shift) == .passToField)   // ⇧⌘Z redo
        }
        #expect(outcome(123, nil, cmd) == .passToField)   // ⌘←
        #expect(outcome(124, nil, cmd) == .passToField)   // ⌘→
        #expect(outcome(51, nil, cmd) == .passToField)    // ⌘⌫
        #expect(outcome(123, nil, cmd | shift) == .passToField)
        #expect(outcome(123, nil, cmd | opt) == .swallow)
    }

    @Test func commandCopyNeedsATextSelectionAndNeverFallsThrough() {
        #expect(outcome(8, "c", cmd, selected: true) == .passToField)
        #expect(outcome(8, "c", cmd, selected: false) == .swallow)
        #expect(outcome(8, "c", cmd | opt, selected: true) == .swallow)   // ⌥⌘C (next code) is not for the panel
    }

    @Test func everythingElseWithCommandIsSwallowedAndNothingWithoutCommandIsACommand() {
        for (code, char) in [(45, "n"), (4, "h"), (12, "q"), (43, ","), (3, "f"), (126, nil as String?), (125, nil)] {
            #expect(outcome(code, char, cmd) == .swallow)
        }
        #expect(outcome(0, "a", 0) == .swallow)
        #expect(outcome(0, "a", opt) == .swallow)
    }
}
