import Foundation
import SQLite3

// Confined to AssetLibraryStore's executor. Values are always bound, never interpolated.
final class LibraryDatabase {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil
            throw LibraryError.message("素材DBを開けません。保存場所の権限を確認してください。")
        }
        do { try script("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;") }
        catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    func script(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let status = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                ?? sqlite3_bind_null(statement, Int32(index + 1))
            guard status == SQLITE_OK else { throw failure() }
        }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
    func execute(_ sql: String, _ values: [String?] = []) throws { _ = try rows(sql, values) }
    func scalar(_ sql: String, _ values: [String?] = []) throws -> String? { try rows(sql, values).first?.values.first }
    func transaction<T>(_ action: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE; PRAGMA defer_foreign_keys=ON;")
        do { let result = try action(); try script("COMMIT"); return result }
        catch { try? script("ROLLBACK"); throw error }
    }
    func backup(to url: URL) throws {
        let target = try LibraryDatabase(url)
        guard let backup = sqlite3_backup_init(target.handle, "main", handle, "main") else { throw failure() }
        let status = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw failure() }
    }
    func restore(from url: URL) throws {
        let source = try LibraryDatabase(url)
        guard let backup = sqlite3_backup_init(handle, "main", source.handle, "main") else { throw failure() }
        let status = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw failure() }
    }
    private func failure() -> LibraryError {
        .message("素材DBの処理に失敗しました（コード \(sqlite3_errcode(handle))）。原本を保持しています。")
    }
}
