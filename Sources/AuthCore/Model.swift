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

    public init(accounts: [Account] = [], groups: [AccountGroup] = AccountGroup.makeDefaults()) {
        self.accounts = accounts
        self.groups = groups
    }

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
