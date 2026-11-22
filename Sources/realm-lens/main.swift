// realm-lens — headless reader.
//
// This exists so the app's data layer can be validated against fixtures WITHOUT building
// or launching the SwiftUI app. It is the app's brain exposed as a testable command.
//
//   realm-lens dump  --space /path/to/.realm            # full snapshot as JSON
//   realm-lens graph --space /path/to/.realm            # derived graph only (nodes+edges+taint)
//   realm-lens check --space /path/to/.realm            # exit 0 if readable, 1 otherwise
//
// Exit codes: 0 ok, 1 read error, 2 usage.

import Foundation
import RealmLensCore

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      realm-lens dump  --space /path/to/.realm [--tail N]
      realm-lens graph --space /path/to/.realm
      realm-lens check --space /path/to/.realm

    Read-only. Never writes to the space.
    """.utf8))
    exit(2)
}

// ---------------------------------------------------------------- json

func jsonString(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out + "\""
}

func jsonOpt(_ s: String?) -> String { s.map(jsonString) ?? "null" }
func jsonOpt(_ n: Int?) -> String { n.map(String.init) ?? "null" }

func nodeJSON(_ n: RealmNode) -> String {
    """
    {"id":\(jsonString(n.id)),"kind":\(jsonString(n.kind.rawValue)),\
    "title":\(jsonString(n.title)),"created_by":\(jsonString(n.createdBy)),\
    "created_at":\(n.createdAt),"updated_at":\(n.updatedAt),\
    "task_state":\(jsonString(n.taskState)),"priority":\(n.priority),"cost":\(n.cost),\
    "fact_status":\(jsonString(n.factStatus)),"check_strength":\(jsonOpt(n.checkStrength)),\
    "assumed":\(n.assumed),"check_cmd":\(jsonOpt(n.checkCmd)),\
    "check_exit":\(jsonOpt(n.checkExit)),"checked_at":\(jsonOpt(n.checkedAt)),\
    "tainted":\(n.tainted),"blocked_by":[\(n.blockedBy.map(jsonString).joined(separator: ","))]}
    """
}

func edgeJSON(_ e: RealmEdge) -> String {
    """
    {"from":\(jsonString(e.from)),"to":\(jsonString(e.to)),"kind":\(jsonString(e.kind))}
    """
}

func leaseJSON(_ l: RealmLease, now: Int) -> String {
    """
    {"resource":\(jsonString(l.resource)),"owner":\(jsonOpt(l.owner)),\
    "fencing_token":\(l.fencingToken),"acquired_at":\(jsonOpt(l.acquiredAt)),\
    "expires_at":\(jsonOpt(l.expiresAt)),"live":\(l.isLive(now: now)),"stale":\(l.isStale(now: now)),\
    "remaining_seconds":\(l.remaining(now: now))}
    """
}

func eventJSON(_ e: RealmEvent) -> String {
    """
    {"cursor":\(e.cursor),"at":\(e.at),"actor":\(jsonString(e.actor)),"op":\(jsonString(e.op)),\
    "node":\(jsonOpt(e.node)),"detail":\(jsonOpt(e.detail)),\
    "is_successful_verify":\(e.isSuccessfulVerify)}
    """
}

func snapshotJSON(_ s: SpaceSnapshot, includeEvents: Bool) -> String {
    let now = Int(Date().timeIntervalSince1970)
    var parts: [String] = []
    parts.append("\"path\":\(jsonString(s.path))")
    parts.append("\"schema_version\":\(s.schemaVersion)")
    parts.append("\"cursor\":\(s.cursor)")
    parts.append("\"read_at\":\(s.readAt)")
    parts.append("\"read_millis\":\(String(format: "%.2f", s.readMillis))")
    parts.append("\"event_tail\":\(s.eventTail)")
    parts.append("\"motion_10m\":\(s.motion(now: now))")
    parts.append("\"nodes\":[\(s.nodes.map(nodeJSON).joined(separator: ","))]")
    parts.append("\"edges\":[\(s.edges.map(edgeJSON).joined(separator: ","))]")
    parts.append("\"leases\":[\(s.leases.map { leaseJSON($0, now: now) }.joined(separator: ","))]")
    if includeEvents {
        parts.append("\"events\":[\(s.events.map(eventJSON).joined(separator: ","))]")
    }
    return "{" + parts.joined(separator: ",") + "}"
}

// ---------------------------------------------------------------- main

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

var spacePath: String?
var tail = 200
var i = 0
while i < args.count {
    switch args[i] {
    case "--space" where i + 1 < args.count: spacePath = args[i + 1]; i += 2
    case "--tail" where i + 1 < args.count: tail = Int(args[i + 1]) ?? 200; i += 2
    default: i += 1
    }
}

let envSpace = ProcessInfo.processInfo.environment["REALM_SPACE"]
let resolved = spacePath ?? envSpace
guard let space = resolved else {
    FileHandle.standardError.write(Data("realm-lens: --space required (or set REALM_SPACE)\n".utf8))
    exit(2)
}

let dir = URL(fileURLWithPath: space)
do {
    let snap = try RealmReader.load(spaceDirectory: dir, eventTail: tail)
    switch cmd {
    case "dump":
        print(snapshotJSON(snap, includeEvents: true))
    case "graph":
        print(snapshotJSON(snap, includeEvents: false))
    case "check":
        print("ok schema=\(snap.schemaVersion) nodes=\(snap.nodes.count) edges=\(snap.edges.count) "
              + "leases=\(snap.leases.count) cursor=\(snap.cursor) \(String(format: "%.2f", snap.readMillis))ms")
    default:
        usage()
    }
} catch let e as SpaceError {
    FileHandle.standardError.write(Data("realm-lens: \(e.description)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("realm-lens: \(error)\n".utf8))
    exit(1)
}
