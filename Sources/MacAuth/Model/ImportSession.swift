import AuthCore
import Foundation
import Observation

/// Everything found by an import, waiting for the user's confirmation. Nothing is stored before.
@MainActor @Observable
final class ImportSession: Identifiable {
    enum Source { case google, link, backup }

    struct Row: Identifiable {
        let id = UUID()
        var account: Account
        var include: Bool
        var groupID: UUID?
        let isDuplicate: Bool
    }

    let id = UUID()
    let source: Source
    var rows: [Row]
    var skipped: [String]
    /// Existing groups first, then groups of a backup that do not exist yet (matched by name).
    var availableGroups: [AccountGroup]
    /// True if the vault does not exist or is replaced: the result becomes the whole vault.
    var replacesVault = false

    init(source: Source, accounts: [Account], skipped: [String] = [], existing: [Account],
         existingGroups: [AccountGroup], backupGroups: [AccountGroup] = [], defaultGroupID: UUID? = nil) {
        self.source = source
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
            if source == .backup {
                target = account.groupID.flatMap { mapping[$0] }
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
