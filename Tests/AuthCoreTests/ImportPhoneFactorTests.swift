import Foundation
import SQLite3
import Testing
@testable import AuthCore

/// Microsoft Authenticator (Android database `PhoneFactor`). Every database is built in the test; invented keys only.
struct ImportPhoneFactorTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let base32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"           // "12345678901234567890"
    static let base64 = Data("12345678901234567890".utf8).base64EncodedString()
    static let schema = "CREATE TABLE accounts (_id INTEGER PRIMARY KEY, name TEXT, username TEXT, oath_secret_key TEXT, account_type INTEGER, cid TEXT);"

    /// Runs SQL in a fresh in-memory database and returns its file image.
    static func database(_ sql: String) throws -> Data {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "SQL: \(String(cString: sqlite3_errmsg(db)))")
        var size: sqlite3_int64 = 0
        let bytes = try #require(sqlite3_serialize(db, "main", &size, 0))
        defer { sqlite3_free(bytes) }
        return Data(bytes: bytes, count: Int(size))
    }

    func result(_ data: Data) throws -> ImportResult {
        guard case .accounts(let r) = try ImportDetector.detect(data, now: now) else {
            throw ImportError.unrecognizedFormat
        }
        return r
    }

    @Test func ordinaryAccountIsBase32WithSixDigits() throws {
        let data = try Self.database(Self.schema + "INSERT INTO accounts (name, username, oath_secret_key, account_type) VALUES ('GitHub', 'alice', '\(Self.base32)', 0);")
        let r = try result(data)
        #expect(r.format == .microsoftAuthenticator && r.skipped.isEmpty && !r.mayBeIncomplete)
        let a = try #require(r.accounts.first)
        #expect(a.issuer == "GitHub" && a.name == "alice" && a.digits == 6 && a.period == 30 && a.algorithm == .sha1 && a.kind == .totp)
        // RFC 6238, SHA1, T = 59 s: 94287082, six digits: 287082.
        #expect(try a.code(at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func personalMicrosoftAccountIsBase64WithEightDigits() throws {
        let data = try Self.database(Self.schema + "INSERT INTO accounts (name, username, oath_secret_key, account_type) VALUES ('Microsoft', 'alice@outlook.com', '\(Self.base64)', 1);")
        let a = try #require(try result(data).accounts.first)
        #expect(a.issuer == "Microsoft" && a.name == "alice@outlook.com" && a.digits == 8 && a.period == 30 && a.algorithm == .sha1)
        #expect(a.secret == Data("12345678901234567890".utf8))
        #expect(try a.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
    }

    @Test func otherTypesAndMissingKeysAreListedWithReason() throws {
        let data = try Self.database(Self.schema + """
        INSERT INTO accounts (name, username, oath_secret_key, account_type) VALUES
          ('Contoso', 'alice@contoso.example', '', 2),
          ('Push', 'bob', '\(Self.base32)', 7),
          ('Leer', 'carol', NULL, 0),
          ('OhneTyp', 'dave', '\(Self.base32)', NULL),
          ('Kaputt', 'erin', '!!!', 0),
          ('Kaputt64', 'frank', '%%%', 1),
          ('Gut', 'grace', '\(Self.base32)', 0);
        """)
        let r = try result(data)
        #expect(r.accounts.map(\.issuer) == ["Gut"])
        #expect(r.accounts[0].sortIndex == 0)
        #expect(r.skipped == [
            SkippedEntry(label: "Contoso (alice@contoso.example)", reason: .noStandardCode),
            SkippedEntry(label: "Push (bob)", reason: .noStandardCode),
            SkippedEntry(label: "Leer (carol)", reason: .noStandardCode),
            SkippedEntry(label: "OhneTyp (dave)", reason: .noStandardCode),
            SkippedEntry(label: "Kaputt (erin)", reason: .invalidSecret),
            SkippedEntry(label: "Kaputt64 (frank)", reason: .invalidSecret),
        ])
        // A reason never carries the key.
        #expect(!r.skipped.contains { "\($0)".contains(Self.base32) })
    }

    @Test func emptyTableGivesNothingToReview() throws {
        let r = try result(try Self.database(Self.schema))
        #expect(r.format == .microsoftAuthenticator && r.hasNothingToReview)
    }

    @Test func otherSQLiteFilesAreNotRecognised() throws {
        #expect(throws: ImportError.unrecognizedFormat) {
            _ = try result(try Self.database("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);"))
        }
        // The table exists but lacks the columns.
        #expect(throws: ImportError.unrecognizedFormat) {
            _ = try result(try Self.database("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT);"))
        }
    }

    /// `accounts` as a view could run arbitrary SQL of the file (other tables, functions): refused, never evaluated.
    @Test func viewNamedAccountsIsRefused() throws {
        let data = try Self.database("""
        CREATE TABLE hidden (name TEXT, username TEXT, oath_secret_key TEXT, account_type INTEGER);
        INSERT INTO hidden VALUES ('GitHub', 'alice', '\(Self.base32)', 0);
        CREATE VIEW accounts AS SELECT name, username, upper(oath_secret_key) AS oath_secret_key, account_type FROM hidden;
        """)
        #expect(throws: ImportError.unrecognizedFormat) { _ = try result(data) }
    }

    @Test func damagedFilesAreRefused() throws {
        var data = try Self.database(Self.schema + "INSERT INTO accounts (name, username, oath_secret_key, account_type) VALUES ('GitHub', 'alice', '\(Self.base32)', 0);")
        // Header only.
        #expect(throws: ImportError.damagedDatabase) { _ = try result(Data(data.prefix(100))) }
        // Schema page overwritten.
        var broken = data
        broken.replaceSubrange(100..<broken.count, with: Data(repeating: 0xA5, count: broken.count - 100))
        #expect(throws: ImportError.damagedDatabase) { _ = try result(broken) }
        // Cut off in the middle of the data: the table's page is missing.
        let pageSize = Int(data[16]) << 8 | Int(data[17])
        #expect(data.count >= 2 * pageSize)
        data = Data(data.prefix(pageSize))
        #expect(throws: ImportError.damagedDatabase) { _ = try result(data) }
    }

    @Test func tooManyRowsAreRefused() throws {
        let rows = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(ImportDetector.maxEntries + 1)) " +
            "INSERT INTO accounts (name, username, oath_secret_key, account_type) SELECT 'A', i, '\(Self.base32)', 0 FROM n;"
        #expect(throws: ImportError.tooManyEntries) { _ = try result(try Self.database(Self.schema + rows)) }
    }

    /// A database copied from a running phone is in write-ahead-log mode. The main file is read as it is and the
    /// result says that accounts may be missing (they could sit in `PhoneFactor-wal` only).
    @Test func writeAheadLogDatabaseIsReadAndMarkedIncomplete() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PhoneFactor")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        let sql = "PRAGMA journal_mode = WAL;" + Self.schema +
            "INSERT INTO accounts (name, username, oath_secret_key, account_type) VALUES ('GitHub', 'alice', '\(Self.base32)', 0);" +
            "PRAGMA wal_checkpoint(TRUNCATE);" +
            "INSERT INTO accounts (name, username, oath_secret_key, account_type) VALUES ('NurImLog', 'bob', '\(Self.base32)', 0);"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        // Copied while the connection is open: the second account is in the -wal file only.
        let data = try Data(contentsOf: file)
        sqlite3_close(db)
        #expect(data[18] == 2 && data[19] == 2)
        let r = try result(data)
        #expect(r.mayBeIncomplete)
        #expect(r.accounts.map(\.issuer) == ["GitHub"])
    }

    /// The log was never written back: the main file is an empty database. Not "unknown format" but a result that
    /// tells the user where the accounts are.
    @Test func writeAheadLogDatabaseWithoutSchemaIsMarkedIncomplete() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PhoneFactor")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        let sql = "PRAGMA journal_mode = WAL;" + Self.schema +
            "INSERT INTO accounts (name, username, oath_secret_key, account_type) VALUES ('NurImLog', 'bob', '\(Self.base32)', 0);"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let data = try Data(contentsOf: file)
        sqlite3_close(db)
        let r = try result(data)
        #expect(r.format == .microsoftAuthenticator && r.mayBeIncomplete && r.hasNothingToReview)
        // An empty database that is not in log mode stays an unknown file.
        var plain = data
        plain[18] = 1; plain[19] = 1
        #expect(throws: ImportError.unrecognizedFormat) { _ = try result(plain) }
    }

    /// Generated columns run expressions of the file. Chains built to burn CPU or memory are cut off quickly.
    @Test func generatedColumnChainsAreCutOff() throws {
        // CPU: every row drags an 800 kB string through 200 replace() calls (half a second per row without the cap).
        var cpu = "CREATE TABLE accounts (username TEXT, oath_secret_key TEXT, account_type INTEGER, c0 TEXT"
        for k in 1...200 { cpu += ", c\(k) TEXT GENERATED ALWAYS AS (replace(c\(k - 1), '0', '0')) VIRTUAL" }
        cpu += ", name TEXT GENERATED ALWAYS AS (substr(c200, 1, 5)) VIRTUAL);"
        cpu += "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2) " +
            "INSERT INTO accounts (username, oath_secret_key, account_type, c0) SELECT i, '\(Self.base32)', 0, hex(zeroblob(400000)) FROM n;"
        // Memory: each column doubles the expression of the one before (about 190 MB at 16 levels without the cap).
        var memory = "CREATE TABLE accounts (username TEXT, oath_secret_key TEXT, account_type INTEGER, c0 INTEGER"
        for k in 1...16 { memory += ", c\(k) INTEGER GENERATED ALWAYS AS (c\(k - 1) + c\(k - 1)) VIRTUAL" }
        memory += ", name TEXT GENERATED ALWAYS AS (c16) VIRTUAL);INSERT INTO accounts (username, oath_secret_key, account_type, c0) VALUES ('a', '\(Self.base32)', 0, 1);"
        for sql in [cpu, memory] {
            let data = try Self.database(sql)
            let started = Date()
            #expect(throws: ImportError.self) { _ = try result(data) }
            #expect(Date().timeIntervalSince(started) < 1)
        }
    }

    /// Steps alone do not bound the time (one step may copy a megabyte), so the read also has a deadline. With a
    /// deadline that has already passed, an honest database with enough rows to reach the check is given up.
    @Test func readStopsAtTheDeadline() throws {
        let rows = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000) " +
            "INSERT INTO accounts (name, username, oath_secret_key, account_type) SELECT 'A', i, '\(Self.base32)', 0 FROM n;"
        let data = try Self.database(Self.schema + rows)
        #expect(throws: ImportError.damagedDatabase) { _ = try ImportDetector.parsePhoneFactor(data, now: now, timeLimit: -1) }
        #expect(try ImportDetector.parsePhoneFactor(data, now: now).accounts.count == 2000)
    }

    @Test func accountTypeStoredAsTextIsAccepted() throws {
        let data = try Self.database("CREATE TABLE accounts (name, username, oath_secret_key, account_type);" +
            "INSERT INTO accounts VALUES ('GitHub', 'alice', '\(Self.base32)', '0'), ('Microsoft', 'bob', '\(Self.base64)', ' 1 '), ('X', 'carol', '\(Self.base32)', 'abc'), ('Y', 'dave', '\(Self.base32)', 0.5);")
        let r = try result(data)
        #expect(r.accounts.map(\.digits) == [6, 8])
        #expect(r.skipped.map(\.reason) == [.noStandardCode, .noStandardCode])
    }

    @Test func detectionDoesNotDisturbTextFormats() throws {
        // Text that merely starts like the signature without the NUL byte is not a database.
        #expect(throws: ImportError.unrecognizedFormat) {
            _ = try ImportDetector.detect(Data("SQLite format 3 is a file format".utf8), now: now)
        }
    }
}
