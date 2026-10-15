#if canImport(SQLite3)
import Foundation
import SQLite3

/// Per-event session log. The table keeps the Windows app's `SessionData`
/// column names (docs/reverse-engineering/features.md section 5) so stats and
/// exports line up; enum-valued columns store this app's own string values
/// because the Windows numeric codes were not recovered.
public final class SessionLog {
    public enum LogError: Error, Equatable {
        case open(String)
        case statement(String)
    }

    private var db: OpaquePointer?

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw LogError.open(message)
        }
        db = handle
        try execute("""
            CREATE TABLE IF NOT EXISTS SessionData (Incident NOT NULL DEFAULT 0, StartTime NOT NULL DEFAULT 0, Duration, Idle,
              ColorChoice, EmailStatus, TextMessageStatus, SurveyStatus, SpecialWinner, SessionResult, FacebookPost,
              FacebookUserPostStatus, PrintChoice, PhotosTaken, PhotoRetakes, ExtraVideos, VideoRetakes, VideosWatched,
              VideosWatchedToCompletion, VideoLengthRecorded, StageReached, PrimaryPrintId, PrimaryPrintCopies, AltPrintId,
              AltPrintCopies, ReprintCopies, KioskReprints, Email TEXT, Phone TEXT, OutputEdf TEXT, SessionPhotos, BurstRetakes);
            CREATE INDEX IF NOT EXISTS SessionTime ON SessionData (StartTime);
            CREATE TABLE IF NOT EXISTS dbProps (Tag TEXT, Value TEXT);
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    public func record(_ summary: SessionSummary, startedAt: Date, duration: TimeInterval, idle: TimeInterval, outputPath: String?) throws {
        let sql = """
            INSERT INTO SessionData (Incident, StartTime, Duration, Idle, ColorChoice, SessionResult, PhotosTaken,
              PhotoRetakes, StageReached, PrimaryPrintCopies, OutputEdf, SessionPhotos)
            VALUES ('photo', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LogError.statement(lastError)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, Int64(startedAt.timeIntervalSince1970))
        sqlite3_bind_double(statement, 2, duration)
        sqlite3_bind_double(statement, 3, idle)
        sqlite3_bind_text(statement, 4, summary.colorChoice.rawValue, -1, transient)
        sqlite3_bind_text(statement, 5, summary.result.rawValue, -1, transient)
        sqlite3_bind_int(statement, 6, Int32(summary.photosTaken))
        sqlite3_bind_int(statement, 7, Int32(summary.photoRetakes))
        sqlite3_bind_text(statement, 8, summary.stageReached, -1, transient)
        sqlite3_bind_int(statement, 9, Int32(summary.printCopies))
        if let outputPath {
            sqlite3_bind_text(statement, 10, outputPath, -1, transient)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_int(statement, 11, Int32(summary.photosTaken))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LogError.statement(lastError)
        }
    }

    /// Count of sessions with the given result, for the stats page.
    public func count(result: SessionResult) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM SessionData WHERE SessionResult = ?", -1, &statement, nil) == SQLITE_OK else {
            throw LogError.statement(lastError)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, result.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw LogError.statement(lastError) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw LogError.statement(message)
        }
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
    }
}
#endif
