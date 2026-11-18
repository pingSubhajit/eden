import Foundation
import SQLite3

// The few things SQLiteReplicaStore needs of SQLite, which macOS and iOS
// carry: open a file, run statements with bound values, read rows, and
// transactions that land whole or not at all. Not a general wrapper.

/// What SQLite said when a statement failed.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite \(code): \(message)" }
}

/// A value bound to a statement's parameter, or read from a column.
enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var text: String? { if case .text(let value) = self { return value } else { return nil } }
    var real: Double? { if case .real(let value) = self { return value } else { return nil } }
    var integer: Int64? { if case .integer(let value) = self { return value } else { return nil } }
    var blob: Data? { if case .blob(let value) = self { return value } else { return nil } }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens (making it if need be) the database at `url`.
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let error = SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open")
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Statements with nothing bound and nothing read, run in order.
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }

    /// A statement run once for each set of values.
    func run(_ sql: String, _ rows: [[SQLiteValue]]) throws {
        guard !rows.isEmpty else { return }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for values in rows {
            try bind(values, to: statement)
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { throw failure(code) }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    /// Every row a query returns, each as its columns' values.
    func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var out: [[SQLiteValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure(code) }
            out.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
        }
        return out
    }

    /// `body` in one transaction: all of it lands, or — when it throws —
    /// none of it does.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: -

    /// Rows changed by every statement since the database was opened.
    var totalChanges: Int { Int(sqlite3_total_changes(handle)) }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { throw failure(code) }
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
            case .real(let number): code = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                // By its length in bytes, not up to a zero byte inside it.
                code = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), SQLiteDatabase.transient)
            case .blob(let data):
                code = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), SQLiteDatabase.transient)
                }
            }
            guard code == SQLITE_OK else { throw failure(code) }
        }
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let start = sqlite3_column_text(statement, index) else { return .text("") }
            return .text(String(decoding: UnsafeBufferPointer(start: start, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func failure(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
