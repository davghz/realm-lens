import XCTest
@testable import RealmLensCore

final class ChangedSinceTests: XCTestCase {
    private func snap(cursors: [Int], tail: Int = 200) -> SpaceSnapshot {
        let evs = cursors.sorted(by: >).map {
            RealmEvent(cursor: $0, at: $0, actor: "a", op: "add", node: nil, detail: nil)
        }
        return SpaceSnapshot(path: "/x", schemaVersion: 2, cursor: cursors.max() ?? 0,
                             nodes: [], edges: [], leases: [], events: evs,
                             eventTail: tail, readAt: 0, readMillis: 0)
    }

    func testZeroNewEventsIsExactNotPartial() {
        // Watermark at the newest event: nothing is new, and that count is exact.
        let s = snap(cursors: [1, 2, 3])
        let r = s.changed(since: 3)
        XCTAssertEqual(r.events.count, 0)
        XCTAssertFalse(r.partial, "0 new events must not be reported as partial")
    }

    func testWatermarkBelowTailIsPartial() {
        // We hold 3..5; watermark 1 means events 2..(before 3) were never loaded.
        let s = snap(cursors: [3, 4, 5])
        let r = s.changed(since: 1)
        XCTAssertTrue(r.partial)
        XCTAssertEqual(r.events.count, 3)
    }

    func testWatermarkReachingTailIsExact() {
        let s = snap(cursors: [3, 4, 5])
        XCTAssertFalse(s.changed(since: 2).partial)
        XCTAssertTrue(s.changed(since: 3).events.count == 2)
        XCTAssertFalse(s.changed(since: 3).partial)
    }

    func testNoWatermarkFullTailIsPartial() {
        let s = snap(cursors: [1, 2, 3], tail: 3)
        XCTAssertTrue(s.changed(since: nil).partial)
    }

    func testNoWatermarkShortHistoryIsExact() {
        let s = snap(cursors: [1, 2], tail: 40)
        XCTAssertFalse(s.changed(since: nil).partial)
    }

    func testEmptyEvents() {
        let s = snap(cursors: [])
        let r = s.changed(since: 5)
        XCTAssertEqual(r.events.count, 0)
        XCTAssertFalse(r.partial)
    }

    // motion must count only successes, and must not match "UNVERIFIED"
    func testMotionCountsOnlySuccessfulVerifies() {
        let ok = RealmEvent(cursor: 1, at: 1000, actor: "a", op: "verify", node: "F1", detail: "VERIFIED exit=0")
        let bad = RealmEvent(cursor: 2, at: 1000, actor: "a", op: "verify", node: "F2", detail: "REFUTED exit=1")
        let unv = RealmEvent(cursor: 3, at: 1000, actor: "a", op: "verify", node: "F3", detail: "UNVERIFIED")
        let s = SpaceSnapshot(path: "/x", schemaVersion: 2, cursor: 3, nodes: [], edges: [],
                              leases: [], events: [unv, bad, ok], eventTail: 40,
                              readAt: 0, readMillis: 0)
        XCTAssertEqual(s.motion(now: 1100, window: 600), 1,
                       "only the VERIFIED event is motion; UNVERIFIED must not match a prefix test")
    }
}
