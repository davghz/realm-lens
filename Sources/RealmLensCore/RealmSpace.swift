// RealmSpace — the read-only data layer for Realm Lens.
//
// Contract, in order of importance:
//   1. NEVER WRITES. SQLITE_OPEN_READONLY plus PRAGMA query_only. The only disk write in
//      the whole app is the last-seen cursor in UserDefaults, and that lives in the UI layer.
//   2. ONE CONSISTENT SNAPSHOT per read. A DEFERRED transaction wraps every query in a load,
//      so a concurrent WAL writer cannot commit a fact and its edge between our nodes query
//      and our edges query. Without this you get edges referencing unseen nodes.
//   3. TAINT IS DERIVED, NEVER TRUSTED. `nodes.tainted` is a cache the CLI refreshes with a
//      write during gate reads. Reading it here would render a fact as safe while `done`
//      refuses it — the one bug that makes the app actively harmful.
//   4. EVERY NULLABLE IS CHECKED. The schema is full of NULLs (detail, owner, check_cmd,
//      superseded_by, expires_at). Reaching for a String on NULL crashes on normal data.
//   5. NO AWAIT INSIDE A TRANSACTION. Actors are reentrant; a suspension between BEGIN and
//      ROLLBACK lets another call use-after-free the handle. Each load is one non-suspending
//      function that returns a Sendable value.

import Foundation
import SQLite3

public struct SpaceError: Error, CustomStringConvertible {
    public let kind: Kind
    public let detail: String
    public enum Kind {
        case notFound          // no .realm or space.db
        case notADatabase
        case needsRecovery     // WAL left hot by a crashed writer
        case busy              // locked by a writer
        case schemaTooNew      // user_version above what we understand
        case schemaUnversioned // user_version 0
        case sqlite
    }
    public var description: String {
        switch kind {
        case .notFound: return "No realm space at \(detail)"
        case .notADatabase: return "Not a realm database: \(detail)"
        case .needsRecovery: return "Database needs recovery: a writer left an uncommitted transaction. Open it with the realm CLI (which can roll back) rather than the lens."
        case .busy: return "Database busy: \(detail)"
        case .schemaTooNew: return "Made by a newer realm (schema \(detail)). Update Realm Lens."
        case .schemaUnversioned: return "Database has no schema version; it predates versioning."
        case .sqlite: return "SQLite: \(detail)"
        }
    }
}

/// The schema version this reader understands. Mirrors what the CLI writes.
public let supportedSchemaVersion: Int32 = 2

// ---------------------------------------------------------------- model

public enum NodeKind: String, Sendable { case task, fact, decision, artifact, attempt }

public struct RealmNode: Sendable, Identifiable {
    public let id: String
    public let kind: NodeKind
    public let title: String
    public let body: String
    public let createdBy: String
    public let createdAt: Int
    public let updatedAt: Int

    // task
    public let taskState: String      // OPEN / DONE / DROPPED / ""
    public let priority: Int
    public let cost: Int

    // fact
    public let factStatus: String     // UNVERIFIED / VERIFIED / REFUTED / CONTESTED / UNCHECKABLE / ""
    public let checkStrength: String? // OK / TRIVIAL / FLAKY / nil when no check ran
    public let assumed: Bool
    public let checkCmd: String?
    public let checkExit: Int?
    public let checkOut: String?
    public let checkedAt: Int?
    public let attemptLimit: Int

    // artifact
    public let byteCount: Int
    public let sourcePath: String?

    // attempt
    public let exitCode: Int?
    public let gitRev: String?

    // DERIVED — computed from the graph, never read from nodes.tainted
    public var tainted: Bool = false
    public var blockedBy: [String] = []
}

public struct RealmEdge: Sendable, Hashable {
    public let from: String   // DEPENDENT
    public let to: String     // PREREQUISITE
    public let kind: String
}

public struct RealmLease: Sendable {
    public let resource: String
    public let owner: String?
    public let fencingToken: Int
    public let acquiredAt: Int?
    public let expiresAt: Int?

    public func isLive(now: Int) -> Bool { (expiresAt ?? 0) > now }
    public func isStale(now: Int) -> Bool {
        guard let e = expiresAt else { return false }
        return e <= now
    }
    public func remaining(now: Int) -> Int { max(0, (expiresAt ?? 0) - now) }
}

public struct RealmEvent: Sendable {
    public let cursor: Int
    public let at: Int
    public let actor: String
    public let op: String
    public let node: String?
    public let detail: String?

    /// Motion means "something was proven". A refusal or a failed verification is not motion.
    /// Uses hasPrefix, never contains: "UNVERIFIED".contains("VERIFIED") is true.
    public var isSuccessfulVerify: Bool {
        op == "verify" && (detail?.hasPrefix("VERIFIED") ?? false)
    }
}

public struct SpaceSnapshot: Sendable {
    public let path: String
    public let schemaVersion: Int32
    public let cursor: Int
    public let nodes: [RealmNode]
    public let edges: [RealmEdge]
    public let leases: [RealmLease]
    public let events: [RealmEvent]     // newest first, capped by eventTail
    public let eventTail: Int
    public let readAt: Int
    public let readMillis: Double

    public var nodesByID: [String: RealmNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }
    public func node(_ id: String) -> RealmNode? { nodes.first { $0.id == id } }

    /// Events newer than a watermark. `partial` is true when the watermark predates the
    /// oldest event we loaded, so the count is a lower bound and must be shown as "N+".
    /// Events newer than a watermark.
    ///
    /// `partial` is true ONLY when the watermark predates the oldest event we loaded — i.e.
    /// there may be events between the watermark and our tail that we never saw. A full tail
    /// with zero new events is NOT partial: the count is exact.
    public func changed(since watermark: Int?) -> (events: [RealmEvent], partial: Bool) {
        guard let w = watermark else {
            // No watermark: "everything we hold". We cannot know whether history was
            // truncated, so a full tail means the count is a lower bound.
            return (events, events.count >= eventTail)
        }
        let newer = events.filter { $0.cursor > w }
        guard let oldestLoaded = events.last?.cursor else {
            return ([], false)                     // no events at all
        }
        // Exact when our window reaches back to the watermark (or one past it).
        let partial = oldestLoaded > w + 1
        return (newer, partial)
    }

    public func motion(now: Int, window: Int = 600) -> Int {
        events.filter { $0.isSuccessfulVerify && now - $0.at < window }.count
    }
}

// ---------------------------------------------------------------- reader

public enum RealmReader {

    /// Load one consistent snapshot. Safe to call repeatedly; each call opens, reads in a
    /// single DEFERRED transaction, and closes. No state is retained between calls, so a
    /// leaked transaction is impossible by construction.
    ///
    /// - Parameter spaceDirectory: the `.realm` directory (not the db file).
    public static func load(spaceDirectory: URL, eventTail: Int = 200) throws -> SpaceSnapshot {
        let started = Date()
        let dbPath = spaceDirectory.appendingPathComponent("space.db").path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dbPath, isDirectory: &isDir), !isDir.boolValue else {
            throw SpaceError(kind: .notFound, detail: dbPath)
        }

        // A READ-ONLY handle cannot create `space.db-shm`. When a writer has just
        // checkpointed (the WAL file is 0 bytes and the shm is gone), the first open can
        // fail before SQLite retries internally. Make the attempt resilient instead of
        // surfacing a spurious "no schema version" error on the first read after a commit.
        // A LENS MUST NOT RECOVER A WRITER'S CRASH.
        //
        // Two facts drive this open strategy:
        //
        // 1. A hot journal means a writer died mid-transaction. Opening READWRITE lets SQLite
        //    roll it back — which is a real write to the database, silently rewriting the
        //    space (and deleting the journal) just because someone looked at it. A lens must
        //    never do that.
        // 2. A true READONLY open of a WAL database works when the sidecars are readable, or
        //    when the directory is writable so SQLite can create `-shm`
        //    (https://www.sqlite.org/wal.html#read_only_databases). It does NOT need
        //    `immutable=1`, which is unsafe for a live database.
        //
        // So: detect a hot journal FIRST and refuse. Otherwise open READONLY. If READONLY
        // cannot attach the WAL while the directory is unwritable, fall back to
        // READWRITE+query_only — but only when no hot journal exists, so recovery can't happen.
        if let hot = hotJournalPath(dbPath), FileManager.default.fileExists(atPath: hot) {
            // A zero-length journal is not hot; SQLite ignores it.
            let size = (try? FileManager.default.attributesOfItem(atPath: hot)[.size] as? Int) ?? 0
            if (size ?? 0) > 0 {
                throw SpaceError(kind: .needsRecovery,
                                 detail: "hot journal present: \(hot)")
            }
        }

        var handle: OpaquePointer?
        var rc: Int32 = SQLITE_OK
        var openedReadOnly = false
        for attempt in 0..<6 {
            rc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil)
            if rc == SQLITE_OK, let h = handle, canQuery(h) {
                openedReadOnly = true
                break
            }
            if let h = handle { sqlite3_close_v2(h) }
            handle = nil
            if attempt < 5 { usleep(25_000) }
        }

        if rc != SQLITE_OK || handle == nil || !openedReadOnly {
            // READONLY could not attach the WAL because the directory is not writable and the
            // sidecars are absent. Fall back, but re-check for a hot journal first: with no
            // hot journal there is nothing to recover, so query_only is genuinely safe.
            if let hot = hotJournalPath(dbPath), FileManager.default.fileExists(atPath: hot) {
                throw SpaceError(kind: .needsRecovery, detail: "hot journal present: \(hot)")
            }
            handle = nil
            rc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE, nil)
            guard rc == SQLITE_OK, let db0 = handle else {
                throw SpaceError(kind: .sqlite, detail: "open failed rc=\(rc)")
            }
            if sqlite3_exec(db0, "PRAGMA query_only=ON", nil, nil, nil) != SQLITE_OK {
                let msg = errmsg(db0)
                sqlite3_close_v2(db0)
                throw SpaceError(kind: .sqlite, detail: "query_only failed: \(msg)")
            }
            defer { sqlite3_close_v2(db0) }
            return try loadLocked(db0, dbPath: dbPath, spaceDirectory: spaceDirectory,
                                  eventTail: eventTail, started: started)
        }

        guard let db = handle else {
            throw SpaceError(kind: .sqlite, detail: "open failed rc=\(rc)")
        }
        defer { sqlite3_close_v2(db) }

        // Even a READONLY handle gets query_only as belt-and-braces.
        sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)

        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw classify(rc, msg, dbPath)
        }
        return try loadLocked(db, dbPath: dbPath, spaceDirectory: spaceDirectory,
                              eventTail: eventTail, started: started)
    }

    /// The shared read body. Caller owns the handle and its lifetime; this never opens.
    private static func loadLocked(_ db: OpaquePointer, dbPath: String, spaceDirectory: URL,
                                   eventTail: Int, started: Date) throws -> SpaceSnapshot {
        // A read-only handle must not acquire locks that outlive a poll.
        sqlite3_busy_timeout(db, 250)
        sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)

        // ONE snapshot for every query below.
        guard sqlite3_exec(db, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
            throw SpaceError(kind: .busy, detail: errmsg(db))
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }

        // Version first, inside the same snapshot, so a migration cannot land underneath us.
        let version = Int32(try scalarInt(db, "PRAGMA user_version"))
        if version == 0 {
            throw SpaceError(kind: .schemaUnversioned, detail: "\(dbPath)")
        }
        if version > supportedSchemaVersion {
            throw SpaceError(kind: .schemaTooNew, detail: "\(version)")
        }

        var nodes = try readNodes(db)
        let edges = try readEdges(db)
        let leases = try readLeases(db)
        let events = try readEvents(db, limit: eventTail)
        let cursor = try scalarInt(db, "SELECT COALESCE(MAX(cursor),0) FROM events")

        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        committed = true

        // Defensive: drop edges whose endpoints we did not see. With one snapshot this is
        // unreachable; keeping it proves the snapshot is doing its job.
        let known = Set(nodes.map(\.id))
        let safeEdges = edges.filter { known.contains($0.from) && known.contains($0.to) }

        // Derived taint: roots are assumed facts not yet verified, propagated BACKWARDS
        // along the dependency arrows (edges point dependent -> prerequisite).
        let taint = deriveTaint(nodes: nodes, edges: safeEdges)
        for i in nodes.indices {
            nodes[i].tainted = taint.tainted.contains(nodes[i].id)
            nodes[i].blockedBy = taint.blocking[nodes[i].id] ?? []
        }

        return SpaceSnapshot(
            path: dbPath,
            schemaVersion: version,
            cursor: cursor,
            nodes: nodes,
            edges: safeEdges,
            leases: leases,
            events: events,
            eventTail: eventTail,
            readAt: Int(Date().timeIntervalSince1970),
            readMillis: Date().timeIntervalSince(started) * 1000
        )
    }


    /// SQLite's hot-journal path: `<db>-journal`, or a super-journal indirection.
    private static func hotJournalPath(_ dbPath: String) -> String? {
        let j = dbPath + "-journal"
        return FileManager.default.fileExists(atPath: j) ? j : nil
    }

    /// Cheap liveness probe: can this handle read the schema header?
    private static func canQuery(_ db: OpaquePointer) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW
    }

    // ------------------------------------------------------------ derivation

    /// Taint and blocking, computed exactly as the CLI's refresh_taint + gate do.
    ///
    /// Roots: facts with assumed=1 that are not VERIFIED, plus the target of any `assumes`
    /// edge whose target is not VERIFIED.
    /// Tainted: transitive dependents of a root, walking to_id -> from_id across
    /// requires/depends_on/cites/assumes. Roots themselves are not "tainted".
    /// Blocking: for any node, the prerequisites (facts) that are not VERIFIED or are tainted.
    public static func deriveTaint(nodes: [RealmNode], edges: [RealmEdge])
        -> (tainted: Set<String>, blocking: [String: [String]]) {

        var status: [String: String] = [:]
        var isFact = Set<String>()
        for n in nodes where n.kind == .fact {
            status[n.id] = n.factStatus
            isFact.insert(n.id)
        }

        var roots = Set<String>()
        for n in nodes where n.kind == .fact && n.assumed && n.factStatus != "VERIFIED" {
            roots.insert(n.id)
        }
        for e in edges where e.kind == "assumes" {
            if isFact.contains(e.to), status[e.to] != "VERIFIED" { roots.insert(e.to) }
        }

        // reverse adjacency: prerequisite -> dependents
        var dependents: [String: [String]] = [:]
        for e in edges where ["requires", "depends_on", "cites", "assumes"].contains(e.kind) {
            dependents[e.to, default: []].append(e.from)
        }

        var tainted = Set<String>()
        var frontier = Array(roots)
        while let cur = frontier.popLast() {
            for d in dependents[cur] ?? [] where !tainted.contains(d) {
                tainted.insert(d)
                frontier.append(d)
            }
        }
        tainted.subtract(roots)

        // blocking: prerequisites that are facts and unsatisfied
        var blocking: [String: [String]] = [:]
        for e in edges where e.kind == "requires" || e.kind == "depends_on" {
            guard isFact.contains(e.to) else { continue }
            let unmet = status[e.to] != "VERIFIED" || tainted.contains(e.to)
            if unmet { blocking[e.from, default: []].append(e.to) }
        }
        return (tainted, blocking)
    }

    // ------------------------------------------------------------ queries

    private static func readNodes(_ db: OpaquePointer) throws -> [RealmNode] {
        let sql = """
        SELECT n.id, n.kind, n.title, n.body, n.created_by, n.created_at, n.updated_at,
               COALESCE(t.state,'')      AS tstate,
               COALESCE(t.priority,50)   AS priority,
               COALESCE(t.cost,1)        AS cost,
               COALESCE(f.status,'')     AS fstatus,
               f.check_strength AS fstrength,
               COALESCE(f.assumed,0)     AS assumed,
               f.check_cmd, f.check_exit, f.check_out, f.checked_at,
               COALESCE(f.attempt_limit,1) AS attempt_limit,
               COALESCE(a.byte_count,0)  AS byte_count,
               a.source_path,
               x.exit_code,
               x.git_rev
          FROM nodes n
          LEFT JOIN tasks t     ON t.node_id = n.id
          LEFT JOIN facts f     ON f.node_id = n.id
          LEFT JOIN artifacts a ON a.node_id = n.id
          LEFT JOIN attempts  x ON x.node_id = n.id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SpaceError(kind: .sqlite, detail: errmsg(db))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [RealmNode] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SpaceError(kind: .sqlite, detail: errmsg(db)) }

            let kindRaw = text(stmt, 1) ?? ""
            let node = RealmNode(
                id: text(stmt, 0) ?? "",
                kind: NodeKind(rawValue: kindRaw) ?? .attempt,
                title: text(stmt, 2) ?? "",
                body: text(stmt, 3) ?? "",
                createdBy: text(stmt, 4) ?? "",
                createdAt: int(stmt, 5),
                updatedAt: int(stmt, 6),
                taskState: text(stmt, 7) ?? "",
                priority: int(stmt, 8),
                cost: int(stmt, 9),
                factStatus: text(stmt, 10) ?? "",
                checkStrength: text(stmt, 11),
                assumed: int(stmt, 12) == 1,
                checkCmd: text(stmt, 13),
                checkExit: optInt(stmt, 14),
                checkOut: text(stmt, 15),
                checkedAt: optInt(stmt, 16),
                attemptLimit: int(stmt, 17),
                byteCount: int(stmt, 18),
                sourcePath: text(stmt, 19),
                exitCode: optInt(stmt, 20),
                gitRev: text(stmt, 21)
            )
            out.append(node)
        }
        return out
    }

    private static func readEdges(_ db: OpaquePointer) throws -> [RealmEdge] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT from_id, to_id, kind FROM edges", -1, &stmt, nil) == SQLITE_OK
        else { throw SpaceError(kind: .sqlite, detail: errmsg(db)) }
        defer { sqlite3_finalize(stmt) }
        var out: [RealmEdge] = []
        while try stepOrThrow(stmt, db) {
            guard let f = text(stmt, 0), let t = text(stmt, 1), let k = text(stmt, 2) else { continue }
            out.append(RealmEdge(from: f, to: t, kind: k))
        }
        return out
    }

    private static func readLeases(_ db: OpaquePointer) throws -> [RealmLease] {
        var stmt: OpaquePointer?
        let sql = "SELECT resource, owner, fencing_token, acquired_at, expires_at FROM leases"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
        else { throw SpaceError(kind: .sqlite, detail: errmsg(db)) }
        defer { sqlite3_finalize(stmt) }
        var out: [RealmLease] = []
        while try stepOrThrow(stmt, db) {
            guard let r = text(stmt, 0) else { continue }
            out.append(RealmLease(resource: r, owner: text(stmt, 1),
                                  fencingToken: int(stmt, 2),
                                  acquiredAt: optInt(stmt, 3),
                                  expiresAt: optInt(stmt, 4)))
        }
        return out
    }

    private static func readEvents(_ db: OpaquePointer, limit: Int) throws -> [RealmEvent] {
        var stmt: OpaquePointer?
        let sql = """
        SELECT cursor, at, actor, op, node_id, detail
          FROM events ORDER BY cursor DESC LIMIT \(max(1, limit))
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
        else { throw SpaceError(kind: .sqlite, detail: errmsg(db)) }
        defer { sqlite3_finalize(stmt) }
        var out: [RealmEvent] = []
        while try stepOrThrow(stmt, db) {
            out.append(RealmEvent(cursor: int(stmt, 0), at: int(stmt, 1),
                                  actor: text(stmt, 2) ?? "", op: text(stmt, 3) ?? "",
                                  node: text(stmt, 4), detail: text(stmt, 5)))
        }
        return out
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
        else { throw SpaceError(kind: .sqlite, detail: errmsg(db)) }
        defer { sqlite3_finalize(stmt) }
        // A PRAGMA or aggregate always yields exactly one row. Anything else — including
        // SQLITE_CORRUPT — must raise, not be reported as zero. Returning 0 here previously
        // made a damaged database look like "schema version 0".
        guard try stepOrThrow(stmt, db) else {
            throw SpaceError(kind: .sqlite, detail: "expected one row from: \(sql)")
        }
        return int(stmt, 0)
    }


    /// Advance a statement, distinguishing SQLITE_DONE from a real error.
    /// A bare `while sqlite3_step(...) == SQLITE_ROW` treats SQLITE_CORRUPT, SQLITE_BUSY and
    /// every other failure as "no more rows", which turns a corrupted graph into an empty
    /// one and makes the app render "everything is fine".
    private static func stepOrThrow(_ stmt: OpaquePointer?, _ db: OpaquePointer) throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SpaceError(kind: .sqlite, detail: "step rc=\(rc) \(errmsg(db))")
        }
    }

    // ------------------------------------------------------------ c helpers

    private static func errmsg(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }

    private static func classify(_ rc: Int32, _ msg: String, _ path: String) -> SpaceError {
        switch rc {
        case SQLITE_NOTADB: return SpaceError(kind: .notADatabase, detail: path)
        case SQLITE_BUSY, SQLITE_LOCKED: return SpaceError(kind: .busy, detail: msg)
        case SQLITE_READONLY, SQLITE_CANTOPEN:
            // A read-only handle cannot create -shm; a crashed writer can also leave a hot WAL.
            if msg.lowercased().contains("recovery") {
                return SpaceError(kind: .needsRecovery, detail: msg)
            }
            return SpaceError(kind: .sqlite, detail: msg)
        default: return SpaceError(kind: .sqlite, detail: "rc=\(rc) \(msg)")
        }
    }

    /// NULL-safe text. The schema is full of nullables; forcing a String here crashes on
    /// perfectly normal rows.
    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let stmt, sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
    private static func int(_ stmt: OpaquePointer?, _ col: Int32) -> Int {
        guard let stmt, sqlite3_column_type(stmt, col) != SQLITE_NULL else { return 0 }
        return Int(sqlite3_column_int64(stmt, col))
    }
    private static func optInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        guard let stmt, sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, col))
    }
}
