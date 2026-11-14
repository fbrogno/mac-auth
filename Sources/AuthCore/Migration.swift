import Foundation

/// One decoded `otpauth-migration://` QR code.
public struct MigrationBatch: Sendable {
    public var accounts: [Account]
    /// Entries that could not be taken over (unsupported algorithm, empty secret), as display labels.
    public var skipped: [String]
    public var version: Int
    /// Number of QR codes the export spans (1 if the export does not say).
    public var batchSize: Int
    /// Zero-based position of this QR code.
    public var batchIndex: Int
    public var batchID: Int32
}

/// Google Authenticator export format (`otpauth-migration://offline?data=<base64 protobuf>`).
public enum MigrationCodec {
    public static let scheme = "otpauth-migration://"
    /// Google Authenticator puts at most this many accounts in one QR code.
    public static let maxAccountsPerCode = 10

    public static func isMigrationURI(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(decoding: s.utf8.prefix(scheme.utf8.count), as: UTF8.self).lowercased() == scheme
    }

    // MARK: Reading

    public static func parse(uri: String, now: Date = Date()) throws -> MigrationBatch {
        let s = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMigrationURI(s) else { throw MigrationError.notMigrationURI }
        let rest = Substring(String(decoding: s.utf8.dropFirst(scheme.utf8.count), as: UTF8.self))
        guard let q = rest.firstIndex(of: "?") else { throw MigrationError.missingData }
        var dataText: String?
        for pair in rest[rest.index(after: q)...].split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            if PercentCoding.decode(pair[..<eq])?.lowercased() == "data" {
                guard let v = PercentCoding.decode(pair[pair.index(after: eq)...]) else { throw MigrationError.invalidBase64 }
                dataText = v
                break
            }
        }
        guard let text = dataText, !text.isEmpty else { throw MigrationError.missingData }
        guard text.utf8.count <= Limits.maxMigrationPayloadBytes / 3 * 4 + 8 else { throw MigrationError.tooLarge }
        guard let payload = Base64Util.decodeFlexible(text) else { throw MigrationError.invalidBase64 }
        return try parse(payload: payload, now: now)
    }

    public static func parse(payload: Data, now: Date = Date()) throws -> MigrationBatch {
        guard payload.count <= Limits.maxMigrationPayloadBytes else { throw MigrationError.tooLarge }
        var reader = ProtoReader([UInt8](payload))
        var batch = MigrationBatch(accounts: [], skipped: [], version: 1, batchSize: 0, batchIndex: 0, batchID: 0)
        while let (field, wire) = try reader.readTag() {
            switch (field, wire) {
            case (1, 2):
                guard batch.accounts.count + batch.skipped.count < Limits.maxMigrationAccounts else {
                    throw MigrationError.tooManyAccounts
                }
                switch try parseParameters(try reader.readBytes(), now: now) {
                case .account(let a): batch.accounts.append(a)
                case .skipped(let label): batch.skipped.append(label)
                }
            case (2, 0): batch.version = Int(Int32(truncatingIfNeeded: try reader.readVarint()))
            case (3, 0): batch.batchSize = Int(Int32(truncatingIfNeeded: try reader.readVarint()))
            case (4, 0): batch.batchIndex = Int(Int32(truncatingIfNeeded: try reader.readVarint()))
            case (5, 0): batch.batchID = Int32(truncatingIfNeeded: try reader.readVarint())
            case (2...5, _): throw MigrationError.malformedProtobuf
            case (1, _): throw MigrationError.malformedProtobuf
            default: try reader.skip(wire: wire)
            }
        }
        if batch.batchSize <= 0 {
            batch.batchSize = 1
            batch.batchIndex = 0
        }
        guard batch.batchIndex >= 0, batch.batchIndex < batch.batchSize, batch.batchSize <= 10_000 else {
            throw MigrationError.inconsistentBatch
        }
        return batch
    }

    private enum Entry {
        case account(Account)
        case skipped(String)
    }

    private static func parseParameters(_ bytes: [UInt8], now: Date) throws -> Entry {
        var r = ProtoReader(bytes)
        var secret: [UInt8] = []
        var name = ""
        var issuer = ""
        var algorithm: UInt64 = 0
        var digits: UInt64 = 0
        var type: UInt64 = 0
        var counter: UInt64 = 0
        while let (field, wire) = try r.readTag() {
            switch (field, wire) {
            case (1, 2): secret = try r.readBytes()
            case (2, 2): name = try text(try r.readBytes())
            case (3, 2): issuer = try text(try r.readBytes())
            case (4, 0): algorithm = try r.readVarint()
            case (5, 0): digits = try r.readVarint()
            case (6, 0): type = try r.readVarint()
            case (7, 0): counter = try r.readVarint()
            case (1...7, _): throw MigrationError.malformedProtobuf
            default: try r.skip(wire: wire)
            }
        }
        // Google often stores the name as "Issuer:name".
        if let colon = name.firstIndex(of: ":") {
            let prefix = name[..<colon].trimmingCharacters(in: .whitespaces)
            let remainder = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if issuer.isEmpty {
                issuer = prefix
                name = remainder
            } else if prefix.caseInsensitiveCompare(issuer) == .orderedSame {
                name = remainder
            }
        }
        let label = issuer.isEmpty ? name : (name.isEmpty ? issuer : "\(issuer) (\(name))")
        let algo: OTPAlgorithm
        switch algorithm {
        case 0, 1: algo = .sha1
        case 2: algo = .sha256
        case 3: algo = .sha512
        default: return .skipped(label)   // MD5 and anything newer
        }
        let digitCount: Int
        switch digits {
        case 0, 1: digitCount = 6
        case 2: digitCount = 8
        default: return .skipped(label)
        }
        let kind: OTPKind
        switch type {
        case 0, 2: kind = .totp
        case 1: kind = .hotp
        default: return .skipped(label)
        }
        guard !secret.isEmpty, secret.count <= Limits.maxSecretBytes else { return .skipped(label) }
        return .account(Account(issuer: issuer, name: name, secret: Data(secret), algorithm: algo, digits: digitCount,
                                kind: kind, counter: counter, createdAt: now))
    }

    private static func text(_ bytes: [UInt8]) throws -> String {
        guard bytes.count <= Limits.maxTextBytes else { throw MigrationError.malformedProtobuf }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Writing

    /// Builds one or more `otpauth-migration://` links ("transfer to phone"). `batchID` is random unless given.
    public static func uris(for accounts: [Account], batchID: Int32? = nil,
                            maxPerCode: Int = maxAccountsPerCode) throws -> [String] {
        let chunkSize = max(1, min(maxPerCode, maxAccountsPerCode))
        let id = batchID ?? Int32.random(in: 1...Int32.max)
        let chunks = stride(from: 0, to: accounts.count, by: chunkSize).map { Array(accounts[$0..<min($0 + chunkSize, accounts.count)]) }
        return try chunks.enumerated().map { index, chunk in
            let payload = try payload(for: chunk, batchSize: chunks.count, batchIndex: index, batchID: id)
            return scheme + "offline?data=" + PercentCoding.encode(payload.base64EncodedString())
        }
    }

    static func payload(for accounts: [Account], batchSize: Int, batchIndex: Int, batchID: Int32) throws -> Data {
        var w = ProtoWriter()
        for account in accounts {
            // Google's format has no period, no 7 digits and a signed 64-bit counter: refuse instead of losing data.
            guard account.digits == 6 || account.digits == 8, !account.secret.isEmpty,
                  account.secret.count <= Limits.maxSecretBytes,
                  account.kind == .hotp || account.period == OTP.defaultPeriod,
                  account.counter <= UInt64(Int64.max),
                  account.name.utf8.count <= Limits.maxTextBytes, account.issuer.utf8.count <= Limits.maxTextBytes
            else {
                throw MigrationError.unsupportedForExport(account.displayLabel)
            }
            var p = ProtoWriter()
            p.bytes(1, [UInt8](account.secret))
            p.string(2, account.name)
            p.string(3, account.issuer)
            p.uint(4, account.algorithm == .sha1 ? 1 : account.algorithm == .sha256 ? 2 : 3)
            p.uint(5, account.digits == 6 ? 1 : 2)
            p.uint(6, account.kind == .hotp ? 1 : 2)
            if account.counter != 0 { p.uint(7, account.counter) }
            w.bytes(1, p.bytes)
        }
        w.uint(2, 1)
        w.int32(3, Int32(batchSize))
        w.int32(4, Int32(batchIndex))
        w.int32(5, batchID)
        return Data(w.bytes)
    }
}

/// Collects the QR codes of a multi-code export ("2 of 3 scanned") and ignores codes scanned twice.
public struct MigrationBatchCollector: Sendable {
    public enum AddResult: Sendable, Equatable {
        case added
        /// This QR code was already collected.
        case duplicate
        /// The code belongs to a different export than the ones collected so far.
        case otherExport
    }

    private var batchID: Int32?
    private var expected = 0
    private var parts: [Int: MigrationBatch] = [:]

    public init() {}

    @discardableResult
    public mutating func add(_ batch: MigrationBatch) -> AddResult {
        if let id = batchID {
            guard id == batch.batchID, expected == batch.batchSize else { return .otherExport }
        } else {
            batchID = batch.batchID
            expected = batch.batchSize
        }
        guard parts[batch.batchIndex] == nil else { return .duplicate }
        parts[batch.batchIndex] = batch
        return .added
    }

    public var scannedCount: Int { parts.count }
    /// Total number of QR codes, known after the first scan.
    public var expectedCount: Int? { batchID == nil ? nil : expected }
    public var isComplete: Bool { batchID != nil && parts.count == expected }
    /// Zero-based indexes of the QR codes still missing.
    public var missingIndexes: [Int] { batchID == nil ? [] : (0..<expected).filter { parts[$0] == nil } }
    /// All accounts collected so far, in QR order.
    public var accounts: [Account] { parts.keys.sorted().flatMap { parts[$0]!.accounts } }
    public var skipped: [String] { parts.keys.sorted().flatMap { parts[$0]!.skipped } }

    public mutating func reset() {
        self = MigrationBatchCollector()
    }
}
