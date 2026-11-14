import Foundation

/// Minimal RFC 4180 reader and writer. Reading is strict about quoting (a closing quote must be followed by a
/// separator) and lenient about line endings (CRLF, LF, lone CR) and blank lines (skipped). Quotes inside an
/// unquoted field are taken literally. Limits come from `Limits`; every failure is a typed `ImportError`.
enum CSV {
    private static let quote = UInt8(ascii: "\"")
    private static let comma = UInt8(ascii: ",")
    private static let lf = UInt8(ascii: "\n")
    private static let cr = UInt8(ascii: "\r")

    /// Parses `text` into records. With `keep`, only the listed columns keep their content (all others become
    /// empty strings), so sensitive columns such as passwords never leave the scanner. `maxRecords` stops early.
    static func parse(_ text: String, maxRecords: Int = Int.max, keep: Set<Int>? = nil) throws -> [[String]] {
        let bytes = Array(text.utf8)
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var fieldStarted = false
        var inQuotes = false
        var afterQuote = false
        var recordHasQuoted = false
        /// Any field of the record held something other than whitespace, also in columns that `keep` drops.
        var recordHasContent = false
        var fieldHasContent = false

        func endField() throws {
            if fieldHasContent { recordHasContent = true }
            fieldHasContent = false
            if record.count >= Limits.maxCSVColumns { throw ImportError.malformedCSV("zu viele Spalten") }
            if keep?.contains(record.count) ?? true {
                record.append(String(decoding: field, as: UTF8.self))
            } else {
                record.append("")
            }
            field.removeAll(keepingCapacity: true)
            fieldStarted = false
            afterQuote = false
        }

        /// Returns false once enough records have been read.
        func endRecord() throws -> Bool {
            defer { record = []; recordHasQuoted = false; recordHasContent = false }
            if record.count == 1, !recordHasContent, !recordHasQuoted { return true }   // blank line
            guard records.count < Limits.maxCSVRows else { throw ImportError.tooManyEntries }
            records.append(record)
            return records.count < maxRecords
        }

        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if inQuotes {
                if b == quote {
                    if i + 1 < n, bytes[i + 1] == quote {
                        field.append(quote)
                        i += 2
                    } else {
                        inQuotes = false
                        afterQuote = true
                        i += 1
                    }
                } else {
                    field.append(b)
                    fieldHasContent = true
                    i += 1
                }
            } else if b == comma {
                try endField()
                i += 1
            } else if b == lf || b == cr {
                try endField()
                if !(try endRecord()) { return records }
                i += (b == cr && i + 1 < n && bytes[i + 1] == lf) ? 2 : 1
            } else if afterQuote {
                throw ImportError.malformedCSV("Text nach schließendem Anführungszeichen")
            } else if b == quote, !fieldStarted {
                inQuotes = true
                fieldStarted = true
                recordHasQuoted = true
                i += 1
            } else {
                fieldStarted = true
                field.append(b)
                if b != UInt8(ascii: " "), b != UInt8(ascii: "\t") { fieldHasContent = true }
                i += 1
            }
            if field.count > Limits.maxCSVFieldBytes { throw ImportError.malformedCSV("Feld zu groß") }
        }
        if inQuotes { throw ImportError.malformedCSV("Anführungszeichen nicht geschlossen") }
        if fieldStarted || afterQuote || !record.isEmpty {
            try endField()
            _ = try endRecord()
        }
        return records
    }

    // MARK: Writing

    /// Quotes a cell when it contains a separator, quote, line break or edge whitespace. No other change.
    static func escape(_ cell: String) -> String {
        let needsQuotes = cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            || cell.first == " " || cell.last == " "
        guard needsQuotes else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
