import Foundation
import SQLite3

/// Reads the account database of Microsoft Authenticator for Android: the SQLite file
/// `/data/data/com.azure.authenticator/databases/PhoneFactor` (readable on rooted devices only).
///
/// Format, read from Aegis' `MicrosoftAuthImporter.java`
/// (https://github.com/beemdevelopment/Aegis/blob/master/app/src/main/java/com/beemdevelopment/aegis/importers/MicrosoftAuthImporter.java):
/// table `accounts` with `name` (issuer), `username`, `oath_secret_key` and `account_type`.
/// - type 0: ordinary TOTP account, Base32 key, 6 digits
/// - type 1: personal Microsoft account, Base64 key, 8 digits
/// - anything else (work accounts with push approval, …) has no standard code and is listed as unusable.
/// Always SHA1 and 30 seconds.
///
/// The file is foreign input. It is opened from memory only (`sqlite3_deserialize`, nothing is written to disk),
/// read-only, with an authorizer that allows nothing but reading the four columns of the table `accounts`:
/// no views, triggers, functions, pragmas or other tables of the file are ever evaluated.
extension ImportDetector {
    static let sqliteMagic = Data("SQLite format 3\u{0}".utf8)

    static func isSQLite(_ data: Data) -> Bool { data.starts(with: sqliteMagic) }

    private static let phoneFactorColumns: Set<String> = ["name", "username", "oath_secret_key", "account_type"]

    static func parsePhoneFactor(_ data: Data, now: Date) throws -> ImportResult {
        // A SQLite header is 100 bytes; the smallest database is one page of at least 512 bytes.
        guard data.count >= 512, data.count <= Limits.maxFileBytes else { throw ImportError.damagedDatabase }
        var image = [UInt8](data)
        // Bytes 18/19 are the file format versions: 2 = write-ahead log. An in-memory image cannot be opened in
        // WAL mode, so it is read as a plain database. Changes that only sit in the companion file
        // `PhoneFactor-wal` are not part of this file; the result is marked as possibly incomplete.
        let usesWAL = image[18] == 2 || image[19] == 2
        if usesWAL { image[18] = 1; image[19] = 1 }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_MEMORY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw ImportError.damagedDatabase
        }
        defer { sqlite3_close(db) }

        guard let buffer = sqlite3_malloc64(sqlite3_uint64(image.count)) else { throw ImportError.damagedDatabase }
        image.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: image.count) }
        // FREEONCLOSE: SQLite owns the buffer from here on, also when the call fails.
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        guard sqlite3_deserialize(db, "main", buffer.assumingMemoryBound(to: UInt8.self), sqlite3_int64(image.count),
                                  sqlite3_int64(image.count), flags) == SQLITE_OK else {
            throw ImportError.damagedDatabase
        }

        // Settings first (the authorizer below refuses pragmas): no SQL from the file's schema is trusted, cells
        // are bounds-checked, and no single value may exceed 1 MB.
        sqlite3_exec(db, "PRAGMA trusted_schema = OFF; PRAGMA cell_size_check = ON;", nil, nil, nil)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_000_000)
        sqlite3_set_authorizer(db, { _, action, arg1, arg2, _, inner in
            switch action {
            case SQLITE_SELECT:
                return SQLITE_OK
            case SQLITE_READ:
                // `inner` names the view or trigger that causes the access: only direct reads are allowed.
                guard inner == nil, let arg1, let arg2, String(cString: arg1).lowercased() == "accounts",
                      ImportDetector.phoneFactorColumns.contains(String(cString: arg2).lowercased()) else { return SQLITE_DENY }
                return SQLITE_OK
            default:
                return SQLITE_DENY
            }
        }, nil)

        var statementHandle: OpaquePointer?
        let sql = "SELECT name, username, oath_secret_key, account_type FROM accounts LIMIT \(maxEntries + 1)"
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statementHandle, nil)
        defer { sqlite3_finalize(statementHandle) }
        guard prepared == SQLITE_OK, let statement = statementHandle else {
            // SQLITE_ERROR: no such table or column, SQLITE_AUTH: `accounts` is a view. Both mean a SQLite file
            // that is not the Microsoft Authenticator database. Everything else is a damaged file.
            throw prepared == SQLITE_ERROR || prepared == SQLITE_AUTH ? ImportError.unrecognizedFormat : ImportError.damagedDatabase
        }

        func columnText(_ index: Int32) -> String {
            guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let c = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var accounts: [Account] = []
        var skipped: [SkippedEntry] = []
        var rows = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ImportError.damagedDatabase }
            rows += 1
            guard rows <= maxEntries else { throw ImportError.tooManyEntries }

            let issuer = clip(columnText(0))
            let name = clip(columnText(1))
            let key = columnText(2)
            let entryLabel = label(title: issuer, username: name, fallback: "Eintrag \(rows)")
            func skip(_ r: SkipReason) { skipped.append(SkippedEntry(label: entryLabel, reason: r)) }

            guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER else { skip(.noStandardCode); continue }
            let type = sqlite3_column_int64(statement, 3)
            // Types other than 0 and 1, and entries without a stored key, are approvals by notification or
            // passwordless sign-in: there is no key a code could be computed from.
            guard type == 0 || type == 1, !key.isEmpty else { skip(.noStandardCode); continue }
            guard key.utf8.count <= Limits.maxBase32InputBytes else { skip(.invalidSecret); continue }
            let secret: Data? = type == 0 ? try? Base32.decode(key) : Base64Util.decodeFlexible(key)
            guard let secret, !secret.isEmpty, secret.count <= Limits.maxSecretBytes else { skip(.invalidSecret); continue }
            accounts.append(Account(issuer: issuer, name: name, secret: secret, algorithm: .sha1, digits: type == 0 ? 6 : 8,
                                    period: OTP.defaultPeriod, kind: .totp, sortIndex: accounts.count, createdAt: now))
        }
        return ImportResult(format: .microsoftAuthenticator, accounts: accounts, groups: [], skipped: skipped,
                            mayBeIncomplete: usesWAL)
    }
}
