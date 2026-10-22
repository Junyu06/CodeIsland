import Foundation
import SQLite3
import CodeIslandCore

/// Read-only access to the SQLite session stores discovery reads: Codex's
/// state database and OpenCode's (and MiMo Code's) store.
enum SQLiteReader {
    static func withSQLiteDatabase<T>(
        at path: String,
        body: (OpaquePointer) -> T?
    ) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        defer { sqlite3_close_v2(db) }
        return body(db)
    }

    static func prepareSQLiteStatement(db: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    static func sqliteTableColumns(
        db: OpaquePointer,
        tableName: String
    ) -> Set<String> {
        guard tableName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let statement = prepareSQLiteStatement(
                db: db,
                sql: "PRAGMA table_info(\(tableName));"
              ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqliteColumnString(statement, index: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    static func bindSQLiteText(_ text: String, to statement: OpaquePointer, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
    }

    static func sqliteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    static func nonEmptySQLiteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqliteColumnString(statement, index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
