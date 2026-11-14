import Foundation

/// One 2FA account. `description`, `debugDescription` and reflection never show the secret.
public struct Account: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var issuer: String
    public var name: String
    public var secret: Data
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int
    public var kind: OTPKind
    public var counter: UInt64
    public var groupID: UUID?
    public var pinned: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var note: String

    public init(id: UUID = UUID(), issuer: String = "", name: String, secret: Data,
                algorithm: OTPAlgorithm = .sha1, digits: Int = 6, period: Int = OTP.defaultPeriod,
                kind: OTPKind = .totp, counter: UInt64 = 0, groupID: UUID? = nil, pinned: Bool = false,
                sortIndex: Int = 0, createdAt: Date = Date(), lastUsedAt: Date? = nil, note: String = "") {
        self.id = id
        self.issuer = issuer
        self.name = name
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.kind = kind
        self.counter = counter
        self.groupID = groupID
        self.pinned = pinned
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.note = note
    }

    /// Checks that code generation will work (non-empty secret, digits and period in range).
    public func validate() throws {
        if secret.isEmpty { throw OTPError.emptySecret }
        if !OTP.allowedDigits.contains(digits) { throw OTPError.invalidDigits(digits) }
        if kind == .totp, !OTP.allowedPeriods.contains(period) { throw OTPError.invalidPeriod(period) }
    }

    /// "Issuer (name)" for lists and error messages; never contains the secret.
    public var displayLabel: String {
        switch (issuer.isEmpty, name.isEmpty) {
        case (false, false): "\(issuer) (\(name))"
        case (false, true): issuer
        case (true, _): name
        }
    }
}

extension Account: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Account(\(displayLabel), \(kind.rawValue), secret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: [
            "id": id, "issuer": issuer, "name": name, "secret": "<redacted>", "algorithm": algorithm,
            "digits": digits, "period": period, "kind": kind,
        ], displayStyle: .struct)
    }
}

/// The fields of an account that the edit sheet can change. Everything else (secret, counter, usage, order) stays
/// as it is in the vault at the moment of saving.
public struct AccountEdit: Equatable, Sendable {
    public var issuer: String
    public var name: String
    public var groupID: UUID?
    public var note: String

    public init(issuer: String, name: String, groupID: UUID?, note: String) {
        self.issuer = issuer
        self.name = name
        self.groupID = groupID
        self.note = note
    }
}

extension Account {
    /// The current account with only the edited fields replaced: an HOTP counter or `lastUsedAt` that moved while
    /// the sheet was open survives.
    public func applying(_ edit: AccountEdit) -> Account {
        var copy = self
        copy.issuer = edit.issuer
        copy.name = edit.name
        copy.groupID = edit.groupID
        copy.note = edit.note
        return copy
    }

    /// The same account without its usage history.
    public var withoutUsage: Account {
        var copy = self
        copy.lastUsedAt = nil
        return copy
    }
}

/// A user-defined group (sidebar entry). Named `AccountGroup` to avoid clashing with `SwiftUI.Group`.
public struct AccountGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    /// Colour as `#RRGGBB`.
    public var colour: String

    public init(id: UUID = UUID(), name: String, symbol: String = "folder", colour: String = "#8E8E93") {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colour = colour
    }

    /// The groups created on first start: "Firma" and "Privat".
    public static func makeDefaults() -> [AccountGroup] {
        [AccountGroup(name: "Firma", symbol: "building.2", colour: "#3B82F6"),
         AccountGroup(name: "Privat", symbol: "house", colour: "#10B981")]
    }
}

/// Everything the vault (and a backup) holds.
public struct VaultData: Codable, Sendable, Equatable {
    public var accounts: [Account]
    public var groups: [AccountGroup]
    /// Security settings of this device's vault. nil = never stored (strict defaults apply). Written to the vault
    /// file only; backups neither carry nor restore it, and imports never merge it.
    public var security: SecuritySettings?

    public init(accounts: [Account] = [], groups: [AccountGroup] = AccountGroup.makeDefaults(), security: SecuritySettings? = nil) {
        self.accounts = accounts
        self.groups = groups
        self.security = security
    }

    /// The same vault without settings (what a backup or an export may hold).
    public var withoutSecuritySettings: VaultData {
        var copy = self
        copy.security = nil
        return copy
    }

    /// The same vault without the usage history (`lastUsedAt`): it only orders the quick access panel and is not a
    /// change a backup or the backup reminder should care about.
    public var withoutUsage: VaultData {
        var copy = self
        copy.accounts = copy.accounts.map(\.withoutUsage)
        return copy
    }

    /// What a backup file holds: no security settings, no usage history.
    public var forBackup: VaultData { withoutSecuritySettings.withoutUsage }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func encoded() throws -> Data { try Self.makeEncoder().encode(self) }
    static func decoded(from data: Data) throws -> VaultData { try makeDecoder().decode(VaultData.self, from: data) }
}

// MARK: - Duplicates

extension Account {
    private struct DuplicateKey: Hashable {
        let secret: Data
        let kind: OTPKind
        let algorithm: OTPAlgorithm
        let digits: Int
        let period: Int
    }

    private var duplicateKey: DuplicateKey {
        // The period is meaningless for HOTP.
        DuplicateKey(secret: secret, kind: kind, algorithm: algorithm, digits: digits, period: kind == .totp ? period : 0)
    }

    /// Same secret bytes and same kind/algorithm/digits/period.
    public func isDuplicate(of other: Account) -> Bool {
        duplicateKey == other.duplicateKey
    }

    /// For each candidate: is it a duplicate of an existing account or of an earlier candidate in the list?
    public static func duplicateFlags(candidates: [Account], existing: [Account]) -> [Bool] {
        var seen = Set(existing.map(\.duplicateKey))
        return candidates.map { !seen.insert($0.duplicateKey).inserted }
    }
}

// MARK: - Merging imports

extension VaultData {
    /// Returns a copy with imported accounts (and their groups) added, without touching existing entries:
    /// - an account whose UUID is already taken gets a new UUID,
    /// - imported groups are merged with existing ones by name (trimmed, case-insensitive) and the accounts'
    ///   `groupID`s are rewritten; unknown names become new groups (new UUID if the id is taken),
    /// - a `groupID` that matches neither an imported nor an existing group is cleared,
    /// - `sortIndex` continues after the highest existing value, in import order.
    /// Duplicate detection is left to the caller (`Account.duplicateFlags`).
    public func merging(accounts imported: [Account], groups importedGroups: [AccountGroup] = []) -> VaultData {
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var result = self
        var groupMap: [UUID: UUID] = [:]
        var byName: [String: UUID] = [:]
        for g in result.groups where byName[key(g.name)] == nil { byName[key(g.name)] = g.id }
        var usedGroupIDs = Set(result.groups.map(\.id))
        for g in importedGroups {
            if let existing = byName[key(g.name)] {
                groupMap[g.id] = existing
                continue
            }
            var added = g
            added.name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if usedGroupIDs.contains(added.id) { added.id = UUID() }
            usedGroupIDs.insert(added.id)
            byName[key(added.name)] = added.id
            groupMap[g.id] = added.id
            result.groups.append(added)
        }
        let knownGroups = Set(result.groups.map(\.id))
        var usedIDs = Set(result.accounts.map(\.id))
        var next = (result.accounts.map(\.sortIndex).max() ?? -1) + 1
        for var a in imported {
            if usedIDs.contains(a.id) { a.id = UUID() }
            usedIDs.insert(a.id)
            if let g = a.groupID {
                let mapped = groupMap[g] ?? g
                a.groupID = knownGroups.contains(mapped) ? mapped : nil
            }
            a.sortIndex = next
            next += 1
            result.accounts.append(a)
        }
        return result
    }
}
