import Foundation

public enum ImportFormat: String, Sendable, Equatable, CaseIterable {
    /// Text file with one `otpauth://` link per line (Ente Auth plain export and many others).
    case otpauthLines
    case aegis
    case twoFAS

    public var displayName: String {
        switch self {
        case .otpauthLines: "otpauth-Liste"
        case .aegis: "Aegis"
        case .twoFAS: "2FAS"
        }
    }
}

public enum SkipReason: Sendable, Equatable {
    case unsupportedType(String)
    case unsupportedAlgorithm(String)
    case invalidSecret
    case invalidParameter(String)
    case notAnOTPAuthLine
    case malformed

    public var description: String {
        switch self {
        case .unsupportedType(let t): "Codetyp „\(t)“ wird nicht unterstützt"
        case .unsupportedAlgorithm(let a): "Algorithmus „\(a)“ wird nicht unterstützt"
        case .invalidSecret: "Schlüssel ungültig"
        case .invalidParameter(let p): "Ungültiger Wert für „\(p)“"
        case .notAnOTPAuthLine: "Keine otpauth-Zeile"
        case .malformed: "Eintrag fehlerhaft"
        }
    }
}

/// An entry that could not be imported. Carries a display label and a reason, never a secret.
public struct SkippedEntry: Sendable, Equatable {
    public var label: String
    public var reason: SkipReason
}

public struct ImportResult: Sendable {
    public var format: ImportFormat
    public var accounts: [Account]
    /// Groups referenced by `accounts[].groupID` (Aegis, 2FAS). Merge with `VaultData.merging`.
    public var groups: [AccountGroup]
    public var skipped: [SkippedEntry]
}

public enum ImportDetection: Sendable {
    case accounts(ImportResult)
    /// Text with `otpauth-migration://` links: take the Google batch path (`MigrationCodec`).
    case googleMigration([String])
    /// A `.macauth` backup: ask for the password and use `BackupFile.decrypt`.
    case macauthBackup
}

/// Recognises a file by its content and reads unencrypted third-party exports.
/// Encrypted Aegis/2FAS files are recognised but never decrypted (`ImportError.encryptedFile`).
///
/// Sources of the formats (read from the projects' code and docs):
/// - Aegis: https://github.com/beemdevelopment/Aegis/blob/master/docs/vault.md
/// - 2FAS: `BackupContent`/`BackupService` in twofas/2fas-android, `ExchangeData*.swift` in twofas/2fas-ios
public enum ImportDetector {
    public static let maxEntries = 10_000

    public static func detect(_ data: Data, now: Date = Date()) throws -> ImportDetection {
        guard !data.isEmpty else { throw ImportError.emptyFile }
        guard data.count <= Limits.maxFileBytes else { throw ImportError.tooLarge }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ImportError.unrecognizedFormat }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyFile }
        if trimmed.hasPrefix("{") {
            return try detectJSON(Data(trimmed.utf8), now: now)
        }
        return try detectLines(trimmed, now: now)
    }

    // MARK: Text

    private static func detectLines(_ text: String, now: Date) throws -> ImportDetection {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count <= maxEntries * 2 else { throw ImportError.tooManyEntries }
        let migration = lines.filter { MigrationCodec.isMigrationURI($0) }
        let otpauth = lines.filter { OTPAuthURI.isOTPAuthURI($0) }
        if otpauth.isEmpty {
            if migration.isEmpty { throw ImportError.unrecognizedFormat }
            guard migration.count <= maxEntries else { throw ImportError.tooManyEntries }
            return .googleMigration(migration)
        }
        guard otpauth.count <= maxEntries else { throw ImportError.tooManyEntries }
        var accounts: [Account] = []
        var skipped: [SkippedEntry] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let label = "Zeile \(index + 1)"
            guard OTPAuthURI.isOTPAuthURI(line) else {
                skipped.append(SkippedEntry(label: label, reason: .notAnOTPAuthLine))
                continue
            }
            do {
                var account = try OTPAuthURI.parse(line, now: now)
                account.sortIndex = accounts.count
                accounts.append(account)
            } catch let e as OTPAuthError {
                skipped.append(SkippedEntry(label: label, reason: reason(for: e)))
            } catch {
                skipped.append(SkippedEntry(label: label, reason: .malformed))
            }
        }
        return .accounts(ImportResult(format: .otpauthLines, accounts: accounts, groups: [], skipped: skipped))
    }

    private static func reason(for error: OTPAuthError) -> SkipReason {
        switch error {
        case .unsupportedType(let t): .unsupportedType(t)
        case .missingSecret, .invalidSecret: .invalidSecret
        case .invalidParameter("algorithm"): .unsupportedAlgorithm("?")
        case .invalidParameter(let p): .invalidParameter(p)
        case .notOTPAuthURI, .malformedURI, .tooLong: .malformed
        }
    }

    // MARK: JSON

    private static func detectJSON(_ data: Data, now: Date) throws -> ImportDetection {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ImportError.unrecognizedFormat
        }
        if root["format"] as? String == BackupFile.formatName { return .macauthBackup }
        if root["header"] != nil, root["db"] != nil { return .accounts(try parseAegis(root, now: now)) }
        if root["services"] != nil || root["servicesEncrypted"] != nil || root["reference"] != nil {
            return .accounts(try parseTwoFAS(root, now: now))
        }
        throw ImportError.unrecognizedFormat
    }

    // MARK: Aegis

    private static func parseAegis(_ root: [String: Any], now: Date) throws -> ImportResult {
        if let v = int(root["version"]), v > 1 { throw ImportError.unsupportedVersion("Aegis \(v)") }
        let header = root["header"] as? [String: Any]
        // Encrypted: `db` is a Base64 string and/or the header carries key slots.
        if root["db"] is String || (header?["slots"] != nil && !(header?["slots"] is NSNull)) {
            throw ImportError.encryptedFile(.aegis)
        }
        guard let db = root["db"] as? [String: Any], let entries = db["entries"] as? [Any] else {
            throw ImportError.unrecognizedFormat
        }
        if let v = int(db["version"]), v > 3 { throw ImportError.unsupportedVersion("Aegis db \(v)") }
        guard entries.count <= maxEntries else { throw ImportError.tooManyEntries }

        var groups: [AccountGroup] = []
        var groupByID: [String: AccountGroup] = [:]
        for case let g as [String: Any] in (db["groups"] as? [Any]) ?? [] {
            guard let uuid = g["uuid"] as? String, let name = text(g["name"]), !name.isEmpty else { continue }
            let group = AccountGroup(name: name)
            groupByID[uuid.lowercased()] = group
            groups.append(group)
        }

        var accounts: [Account] = []
        var skipped: [SkippedEntry] = []
        for case let e as [String: Any] in entries {
            let issuer = text(e["issuer"]) ?? ""
            let name = text(e["name"]) ?? ""
            let label = issuer.isEmpty ? name : (name.isEmpty ? issuer : "\(issuer) (\(name))")
            func skip(_ r: SkipReason) { skipped.append(SkippedEntry(label: label, reason: r)) }
            guard let type = (e["type"] as? String)?.lowercased(), let info = e["info"] as? [String: Any] else { skip(.malformed); continue }
            guard type == "totp" || type == "hotp" else { skip(.unsupportedType(String(type.prefix(16)))); continue }
            guard let secret = secret(info["secret"]) else { skip(.invalidSecret); continue }
            guard let algorithm = algorithm(info["algo"]) else {
                skip(.unsupportedAlgorithm(String(((info["algo"] as? String) ?? "?").prefix(16)))); continue
            }
            guard let digits = int(info["digits"]), OTP.allowedDigits.contains(digits) else { skip(.invalidParameter("digits")); continue }
            var period = OTP.defaultPeriod
            var counter: UInt64 = 0
            if type == "totp" {
                guard let p = int(info["period"]), OTP.allowedPeriods.contains(p) else { skip(.invalidParameter("period")); continue }
                period = p
            } else {
                guard let c = uint(info["counter"]) else { skip(.invalidParameter("counter")); continue }
                counter = c
            }
            guard issuer.utf8.count <= Limits.maxTextBytes, name.utf8.count <= Limits.maxTextBytes else { skip(.malformed); continue }
            var groupID: UUID?
            for case let g as String in (e["groups"] as? [Any]) ?? [] {
                if let group = groupByID[g.lowercased()] { groupID = group.id; break }
            }
            accounts.append(Account(issuer: issuer, name: name, secret: secret, algorithm: algorithm, digits: digits,
                                    period: period, kind: type == "hotp" ? .hotp : .totp, counter: counter,
                                    groupID: groupID, pinned: (e["favorite"] as? Bool) ?? false,
                                    sortIndex: accounts.count, createdAt: now, note: String((text(e["note"]) ?? "").prefix(Limits.maxTextBytes))))
        }
        return ImportResult(format: .aegis, accounts: accounts, groups: groups, skipped: skipped)
    }

    // MARK: 2FAS

    private static func parseTwoFAS(_ root: [String: Any], now: Date) throws -> ImportResult {
        if let v = int(root["schemaVersion"]), v > 4 { throw ImportError.unsupportedVersion("2FAS \(v)") }
        let reference = (root["reference"] as? String) ?? ""
        let encrypted = (root["servicesEncrypted"] as? String) ?? ""
        if !reference.isEmpty || !encrypted.isEmpty { throw ImportError.encryptedFile(.twoFAS) }
        guard let services = root["services"] as? [Any] else { throw ImportError.unrecognizedFormat }
        guard services.count <= maxEntries else { throw ImportError.tooManyEntries }

        var groups: [AccountGroup] = []
        var groupByID: [String: AccountGroup] = [:]
        for case let g as [String: Any] in (root["groups"] as? [Any]) ?? [] {
            guard let id = g["id"] as? String, let name = text(g["name"]), !name.isEmpty else { continue }
            let group = AccountGroup(name: name)
            groupByID[id.lowercased()] = group
            groups.append(group)
        }

        let sorted = services.compactMap { $0 as? [String: Any] }.enumerated().sorted { a, b in
            let pa = int((a.element["order"] as? [String: Any])?["position"]) ?? Int.max
            let pb = int((b.element["order"] as? [String: Any])?["position"]) ?? Int.max
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)

        var accounts: [Account] = []
        var skipped: [SkippedEntry] = []
        for s in sorted {
            let otp = (s["otp"] as? [String: Any]) ?? [:]
            let serviceName = text(s["name"]) ?? ""
            let issuerField = text(otp["issuer"]) ?? ""
            let issuer = issuerField.isEmpty ? serviceName : issuerField
            let name = text(otp["account"]) ?? ""
            let label = issuer.isEmpty ? name : (name.isEmpty ? issuer : "\(issuer) (\(name))")
            func skip(_ r: SkipReason) { skipped.append(SkippedEntry(label: label, reason: r)) }
            let tokenType = ((otp["tokenType"] as? String) ?? "TOTP").uppercased()
            guard tokenType == "TOTP" || tokenType == "HOTP" else { skip(.unsupportedType(String(tokenType.prefix(16)))); continue }
            guard let secret = secret(s["secret"]) else { skip(.invalidSecret); continue }
            let algorithmText = otp["algorithm"] as? String
            guard let algorithm = algorithmText == nil ? OTPAlgorithm.sha1 : algorithm(algorithmText) else {
                skip(.unsupportedAlgorithm(String((algorithmText ?? "?").prefix(16)))); continue
            }
            let digits = otp["digits"] == nil || otp["digits"] is NSNull ? 6 : (int(otp["digits"]) ?? 0)
            guard OTP.allowedDigits.contains(digits) else { skip(.invalidParameter("digits")); continue }
            var period = OTP.defaultPeriod
            var counter: UInt64 = 0
            if tokenType == "TOTP" {
                if otp["period"] != nil, !(otp["period"] is NSNull) {
                    guard let p = int(otp["period"]), OTP.allowedPeriods.contains(p) else { skip(.invalidParameter("period")); continue }
                    period = p
                }
            } else if otp["counter"] != nil, !(otp["counter"] is NSNull) {
                guard let c = uint(otp["counter"]) else { skip(.invalidParameter("counter")); continue }
                counter = c
            }
            guard issuer.utf8.count <= Limits.maxTextBytes, name.utf8.count <= Limits.maxTextBytes else { skip(.malformed); continue }
            var created = now
            if let ms = int(s["updatedAt"]), ms > 0, ms < 4_000_000_000_000 { created = Date(timeIntervalSince1970: Double(ms) / 1000) }
            let groupID = (s["groupId"] as? String).flatMap { groupByID[$0.lowercased()]?.id }
            accounts.append(Account(issuer: issuer, name: name, secret: secret, algorithm: algorithm, digits: digits,
                                    period: period, kind: tokenType == "HOTP" ? .hotp : .totp, counter: counter,
                                    groupID: groupID, sortIndex: accounts.count, createdAt: created))
        }
        return ImportResult(format: .twoFAS, accounts: accounts, groups: groups, skipped: skipped)
    }

    // MARK: JSON value helpers

    private static func text(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    private static func int(_ value: Any?) -> Int? {
        guard let n = number(value), Double(n.int64Value) == n.doubleValue else { return nil }
        return Int(exactly: n.int64Value)
    }

    private static func uint(_ value: Any?) -> UInt64? {
        guard let n = number(value), n.doubleValue >= 0 else { return nil }
        return n.uint64Value
    }

    private static func secret(_ value: Any?) -> Data? {
        guard let s = value as? String, let data = try? Base32.decode(s), !data.isEmpty, data.count <= Limits.maxSecretBytes else { return nil }
        return data
    }

    private static func algorithm(_ value: Any?) -> OTPAlgorithm? {
        switch (value as? String)?.uppercased() {
        case "SHA1": .sha1
        case "SHA256": .sha256
        case "SHA512": .sha512
        default: nil
        }
    }
}
