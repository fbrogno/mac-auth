import Foundation

public enum ImportFormat: String, Sendable, Equatable, CaseIterable {
    /// Text file with one `otpauth://` link per line (Ente Auth plain export and many others).
    case otpauthLines
    case aegis
    case twoFAS
    /// CSV export of the macOS/iOS Passwords app (`Title,URL,Username,Password,Notes,OTPAuth`).
    case applePasswordsCSV
    /// Any other CSV with a header row and a column holding `otpauth://` links or Base32 setup keys.
    case genericCSV
    /// Bitwarden unencrypted JSON export.
    case bitwarden
    /// andOTP plain-text JSON backup.
    case andOTP
    /// Account database of Microsoft Authenticator for Android (SQLite file `PhoneFactor`, rooted devices only).
    case microsoftAuthenticator

    public var displayName: String {
        switch self {
        case .otpauthLines: "otpauth-Liste"
        case .aegis: "Aegis"
        case .twoFAS: "2FAS"
        case .applePasswordsCSV: "Apple Passwörter (CSV)"
        case .genericCSV: "CSV"
        case .bitwarden: "Bitwarden"
        case .andOTP: "andOTP"
        case .microsoftAuthenticator: "Microsoft Authenticator"
        }
    }
}

public enum SkipReason: Error, Sendable, Equatable {
    case unsupportedType(String)
    case unsupportedAlgorithm(String)
    case invalidSecret
    case invalidParameter(String)
    case notAnOTPAuthLine
    case malformed
    /// The source app holds no key for this entry (approval by notification, passwordless sign-in).
    case noStandardCode

    public var description: String {
        switch self {
        case .unsupportedType(let t): "Codetyp „\(t)“ wird nicht unterstützt"
        case .unsupportedAlgorithm(let a): "Algorithmus „\(a)“ wird nicht unterstützt"
        case .invalidSecret: "Schlüssel ungültig"
        case .invalidParameter(let p): "Ungültiger Wert für „\(p)“"
        case .notAnOTPAuthLine: "Keine otpauth-Zeile"
        case .malformed: "Eintrag fehlerhaft"
        case .noStandardCode: "Kein Einmalcode hinterlegt (Anmeldung per Mitteilung oder ohne Passwort)"
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
    /// Rows/items that carry no one-time code at all (typical for password-manager exports). Not an error;
    /// the UI can say "37 Einträge ohne Code übersprungen". Their content is never kept.
    public var rowsWithoutCode: Int = 0
    /// The source may hold more accounts than this file shows: a Microsoft Authenticator database copied while
    /// its write-ahead log (`PhoneFactor-wal`) still held changes. The UI asks the user to compare the list.
    public var mayBeIncomplete: Bool = false

    /// Nothing the user could review or be told about: no account and no unusable entry. The app shows
    /// "Keine Codes gefunden" instead of an empty review sheet.
    public var hasNothingToReview: Bool { accounts.isEmpty && skipped.isEmpty }
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
/// - Apple Passwords CSV: header `Title,URL,Username,Password,Notes,OTPAuth`; the OTPAuth cell holds an
///   `otpauth://totp?secret=…` link without label (community sources; Apple publishes no specification)
/// - Bitwarden: https://bitwarden.com/help/condition-bitwarden-import/ (`items[].login.totp`, `encrypted`)
/// - andOTP: https://github.com/andOTP/andOTP/wiki/Backup-Format and `Entry.java` (JSON array, Base32 secret)
/// - Microsoft Authenticator (Android database `PhoneFactor`): see `ImportPhoneFactor.swift`
/// A password-manager file is read into memory for parsing; only the OTP and label columns are kept in a result and
/// nothing else is retained after the parse.
public enum ImportDetector {
    public static let maxEntries = 10_000

    public static func detect(_ data: Data, now: Date = Date()) throws -> ImportDetection {
        guard !data.isEmpty else { throw ImportError.emptyFile }
        guard data.count <= Limits.maxFileBytes else { throw ImportError.tooLarge }
        // Binary formats first: a SQLite file is never valid UTF-8 text.
        if isSQLite(data) { return .accounts(try parsePhoneFactor(data, now: now)) }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ImportError.unrecognizedFormat }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyFile }
        if trimmed.hasPrefix("{") {
            return try detectJSON(Data(trimmed.utf8), now: now)
        }
        if trimmed.hasPrefix("[") {
            return .accounts(try parseAndOTP(Data(trimmed.utf8), now: now))
        }
        if let csv = try detectCSV(text, now: now) { return .accounts(csv) }
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
        if root["items"] != nil || root["encrypted"] != nil { return .accounts(try parseBitwarden(root, now: now)) }
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

    // MARK: OTP values shared by CSV, Bitwarden and andOTP

    /// Turns the OTP cell of a password-manager export into an account: an `otpauth://` link or a bare Base32
    /// setup key (then SHA1/6/30). Issuer and name from the link win; missing parts come from `title`/`username`.
    /// The failure reason never contains the value.
    ///
    /// `titleIsNameWithoutUsername` (Apple Passwords CSV): an account exported without issuer has its name in the
    /// Title column and an empty Username; reading that back as issuer would swap issuer and name.
    private static func account(fromOTPValue raw: String, title: String, username: String, now: Date,
                                titleIsNameWithoutUsername: Bool = false) -> Result<Account, SkipReason> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("steam://") { return .failure(.unsupportedType("steam")) }
        var account: Account
        if OTPAuthURI.isOTPAuthURI(value) {
            do { account = try OTPAuthURI.parse(value, now: now) } catch let e as OTPAuthError {
                return .failure(reason(for: e))
            } catch { return .failure(.malformed) }
        } else {
            guard !value.contains("://"), let secret = try? Base32.decode(value), !secret.isEmpty,
                  secret.count <= Limits.maxSecretBytes else { return .failure(.invalidSecret) }
            account = Account(name: "", secret: secret, createdAt: now)
        }
        if titleIsNameWithoutUsername, account.issuer.isEmpty, account.name.isEmpty,
           username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            account.name = clip(title)
            return .success(account)
        }
        if account.issuer.isEmpty { account.issuer = clip(title) }
        if account.name.isEmpty { account.name = clip(username) }
        return .success(account)
    }

    static func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.utf8.count > Limits.maxTextBytes else { return t }
        var out = ""
        var bytes = 0
        for ch in t {
            bytes += String(ch).utf8.count
            if bytes > Limits.maxTextBytes { break }
            out.append(ch)
        }
        return out
    }

    static func label(title: String, username: String, fallback: String) -> String {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let u = String(username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        switch (t.isEmpty, u.isEmpty) {
        case (false, false): return "\(t) (\(u))"
        case (false, true): return t
        case (true, false): return u
        case (true, true): return fallback
        }
    }

    // MARK: CSV (Apple Passwords and generic)

    private static let otpColumnNames = ["otpauth", "totp", "login_totp", "2fa", "otp", "one-time password", "one time password"]
    private static let titleColumnNames = ["title", "name", "service", "issuer", "login_name"]
    private static let usernameColumnNames = ["username", "login_username", "user name", "email", "e-mail", "login", "account"]
    private static let appleHeader = ["title", "url", "username", "password", "notes", "otpauth"]

    /// Returns nil when the text is not a CSV with a recognisable OTP column (the caller then tries other formats).
    private static func detectCSV(_ text: String, now: Date) throws -> ImportResult? {
        // Blank lines (and indentation) before the header are skipped.
        let text = String(text.drop(while: { $0.isWhitespace || $0.isNewline }))
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" })
        guard firstLine.contains(","), !OTPAuthURI.isOTPAuthURI(String(firstLine)),
              !MigrationCodec.isMigrationURI(String(firstLine)) else { return nil }
        guard let headerRow = (try? CSV.parse(text, maxRecords: 1))?.first else { return nil }
        let names = headerRow.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ candidates: [String]) -> Int? {
            for c in candidates { if let i = names.firstIndex(of: c) { return i } }
            return nil
        }
        guard let otpColumn = column(otpColumnNames) else { return nil }
        var seen = Set<String>()
        for n in names where !n.isEmpty {
            guard seen.insert(n).inserted else { throw ImportError.malformedCSV("doppelte Spaltennamen") }
        }
        let titleColumn = column(titleColumnNames)
        let userColumn = column(usernameColumnNames)
        // Only these columns are read; every other column (notably the password) is dropped while scanning.
        let keep = Set([otpColumn, titleColumn, userColumn].compactMap { $0 })
        let rows = try CSV.parse(text, keep: keep).dropFirst()
        let format: ImportFormat = names == appleHeader ? .applePasswordsCSV : .genericCSV

        var accounts: [Account] = []
        var skipped: [SkippedEntry] = []
        var withoutCode = 0
        for (offset, row) in rows.enumerated() {
            func cell(_ c: Int?) -> String { c.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            let otp = cell(otpColumn)
            if otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { withoutCode += 1; continue }
            let title = cell(titleColumn), username = cell(userColumn)
            switch account(fromOTPValue: otp, title: title, username: username, now: now, titleIsNameWithoutUsername: format == .applePasswordsCSV) {
            case .success(var account):
                account.sortIndex = accounts.count
                accounts.append(account)
            case .failure(let reason):
                skipped.append(SkippedEntry(label: label(title: title, username: username, fallback: "Zeile \(offset + 2)"), reason: reason))
            }
        }
        // A "CSV" that is really a list of otpauth lines (its first line only happened to contain a comma and a
        // word like otp) yields nothing as CSV: let the line reader have it.
        if accounts.isEmpty, skipped.isEmpty,
           text.split(whereSeparator: \.isNewline).contains(where: { OTPAuthURI.isOTPAuthURI($0.trimmingCharacters(in: .whitespaces)) }) {
            return nil
        }
        return ImportResult(format: format, accounts: accounts, groups: [], skipped: skipped, rowsWithoutCode: withoutCode)
    }

    // MARK: Bitwarden

    private static func parseBitwarden(_ root: [String: Any], now: Date) throws -> ImportResult {
        if (root["encrypted"] as? Bool) == true || (root["passwordProtected"] as? Bool) == true {
            throw ImportError.encryptedFile(.bitwarden)
        }
        guard let items = root["items"] as? [Any] else { throw ImportError.unrecognizedFormat }
        guard items.count <= maxEntries else { throw ImportError.tooManyEntries }
        var accounts: [Account] = []
        var skipped: [SkippedEntry] = []
        var withoutCode = 0
        for (index, any) in items.enumerated() {
            guard let item = any as? [String: Any] else { skipped.append(SkippedEntry(label: "Eintrag \(index + 1)", reason: .malformed)); continue }
            let login = item["login"] as? [String: Any]
            let totp = (login?["totp"] as? String) ?? ""
            if totp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { withoutCode += 1; continue }
            let title = text(item["name"]) ?? ""
            let username = text(login?["username"]) ?? ""
            switch account(fromOTPValue: totp, title: title, username: username, now: now) {
            case .success(var account):
                account.sortIndex = accounts.count
                accounts.append(account)
            case .failure(let reason):
                skipped.append(SkippedEntry(label: label(title: title, username: username, fallback: "Eintrag \(index + 1)"), reason: reason))
            }
        }
        return ImportResult(format: .bitwarden, accounts: accounts, groups: [], skipped: skipped, rowsWithoutCode: withoutCode)
    }

    // MARK: andOTP

    private static func parseAndOTP(_ data: Data, now: Date) throws -> ImportResult {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let first = array.first as? [String: Any], first["secret"] != nil, first["label"] != nil else {
            throw ImportError.unrecognizedFormat
        }
        guard array.count <= maxEntries else { throw ImportError.tooManyEntries }
        var accounts: [Account] = []
        var skipped: [SkippedEntry] = []
        for (index, any) in array.enumerated() {
            guard let e = any as? [String: Any] else { skipped.append(SkippedEntry(label: "Eintrag \(index + 1)", reason: .malformed)); continue }
            let issuer = text(e["issuer"]) ?? ""
            let name = text(e["label"]) ?? ""
            let entryLabel = label(title: issuer, username: name, fallback: "Eintrag \(index + 1)")
            func skip(_ r: SkipReason) { skipped.append(SkippedEntry(label: entryLabel, reason: r)) }
            let type = ((e["type"] as? String) ?? "TOTP").uppercased()
            guard type == "TOTP" || type == "HOTP" else { skip(.unsupportedType(String(type.lowercased().prefix(16)))); continue }
            guard let secret = secret(e["secret"]) else { skip(.invalidSecret); continue }
            let algorithmText = e["algorithm"] as? String
            guard let algorithm = algorithmText == nil ? OTPAlgorithm.sha1 : algorithm(algorithmText) else {
                skip(.unsupportedAlgorithm(String((algorithmText ?? "?").prefix(16)))); continue
            }
            let digits = e["digits"] == nil ? 6 : (int(e["digits"]) ?? 0)
            guard OTP.allowedDigits.contains(digits) else { skip(.invalidParameter("digits")); continue }
            var period = OTP.defaultPeriod
            var counter: UInt64 = 0
            if type == "TOTP" {
                if e["period"] != nil {
                    guard let p = int(e["period"]), OTP.allowedPeriods.contains(p) else { skip(.invalidParameter("period")); continue }
                    period = p
                }
            } else {
                guard let c = uint(e["counter"]) else { skip(.invalidParameter("counter")); continue }
                counter = c
            }
            guard issuer.utf8.count <= Limits.maxTextBytes, name.utf8.count <= Limits.maxTextBytes else { skip(.malformed); continue }
            accounts.append(Account(issuer: issuer, name: name, secret: secret, algorithm: algorithm, digits: digits,
                                    period: period, kind: type == "HOTP" ? .hotp : .totp, counter: counter,
                                    sortIndex: accounts.count, createdAt: now))
        }
        return ImportResult(format: .andOTP, accounts: accounts, groups: [], skipped: skipped)
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

    /// An exact non-negative integer up to `UInt64.max`. Fractions (`5.7`), negative numbers and values that do not
    /// fit (`1e30`) are refused instead of being converted.
    private static func uint(_ value: Any?) -> UInt64? {
        guard let n = number(value) else { return nil }
        switch String(cString: n.objCType) {
        case "d", "f":
            // JSON numbers written with a fraction or exponent: only whole numbers that a double holds exactly.
            let d = n.doubleValue
            guard d >= 0, d == d.rounded(.towardZero), d < 9_007_199_254_740_992 else { return nil }
            return UInt64(d)
        case "Q":
            return n.uint64Value
        default:
            let v = n.int64Value
            return v >= 0 ? UInt64(v) : nil
        }
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
