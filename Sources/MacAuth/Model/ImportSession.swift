import AuthCore
import Foundation
import Observation

/// Everything found by an import, waiting for the user's confirmation. Nothing is stored before.
@MainActor @Observable
final class ImportSession: Identifiable {
    enum Source { case google, link, backup, file }
    /// How the data arrived; decides the clean-up hint after a successful import.
    /// `passwordFile` is an export of a password manager (Apple Passwords, Bitwarden, CSV): it holds every password.
    enum Delivery { case camera, image, file, passwordFile, text, backup }

    struct Row: Identifiable {
        let id = UUID()
        var account: Account
        var include: Bool
        var groupID: UUID?
        let isDuplicate: Bool
    }

    let id = UUID()
    let source: Source
    let delivery: Delivery
    /// What this session may do; fixed at creation, never derived from the phase at confirmation time.
    let intent: ImportIntent
    /// Rescue path: set once the user confirmed that the old vault file is kept and a new vault replaces it.
    var replaceConfirmed = false
    /// Detected file format (file imports only); shown in the review sheet.
    let format: ImportFormat?
    /// Rows of a password-manager file that carry no code and were skipped. Their content is never kept.
    let rowsWithoutCode: Int
    var rows: [Row]
    var skipped: [String]
    /// Existing groups first, then groups of a backup that do not exist yet (matched by name).
    var availableGroups: [AccountGroup]
    var replacesVault: Bool { intent == .replaceVault }
    /// The file came from a password manager: only the codes are read, the passwords in it are ignored.
    var fileHasPasswords: Bool { delivery == .passwordFile }

    init(source: Source, delivery: Delivery, intent: ImportIntent, accounts: [Account], skipped: [String] = [], existing: [Account],
         existingGroups: [AccountGroup], incomingGroups backupGroups: [AccountGroup] = [], defaultGroupID: UUID? = nil,
         format: ImportFormat? = nil, rowsWithoutCode: Int = 0) {
        self.format = format
        self.rowsWithoutCode = rowsWithoutCode
        self.source = source
        self.delivery = delivery
        self.intent = intent
        self.skipped = skipped
        var groups = existingGroups
        var mapping: [UUID: UUID] = [:]
        for group in backupGroups {
            if let match = existingGroups.first(where: { $0.name.compare(group.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                mapping[group.id] = match.id
            } else {
                groups.append(group)
                mapping[group.id] = group.id
            }
        }
        availableGroups = groups
        let flags = Account.duplicateFlags(candidates: accounts, existing: existing)
        rows = zip(accounts, flags).map { account, duplicate in
            var target: UUID?
            if source == .backup || source == .file {
                target = account.groupID.flatMap { mapping[$0] } ?? (source == .file ? defaultGroupID : nil)
            } else {
                target = defaultGroupID
            }
            return Row(account: account, include: !duplicate, groupID: target, isDuplicate: duplicate)
        }
    }

    var selectedCount: Int { rows.filter(\.include).count }
    var duplicateCount: Int { rows.filter(\.isDuplicate).count }

    func setGroupForAll(_ id: UUID?) {
        for index in rows.indices { rows[index].groupID = id }
    }

    func setAll(included: Bool) {
        for index in rows.indices { rows[index].include = included ? !rows[index].isDuplicate : false }
    }
}
