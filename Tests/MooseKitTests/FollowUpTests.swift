import XCTest
@testable import MooseKit

final class FollowUpTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }   // 2026-10-23 is a Friday

    func msg(_ id: String = "m1", thread: String = "t1", unread: Bool = true) -> MailMessage {
        MailMessage(id: id, threadId: thread, account: "me@gmail.com", fromName: "Maya", fromEmail: "maya@acme.example", subject: "Contract", snippet: "Can you sign?",
                    date: date(2026, 10, 20), unread: unread)
    }

    func testSnoozeHidesThenResurfacesAtTheTop() {
        let now = date(2026, 10, 23)
        var list: [FollowUp] = []
        FollowUps.add(FollowUp(kind: .snooze, message: msg(), created: now, due: date(2026, 10, 24, 9)), to: &list)
        let hidden = Priority.score(msg(unread: false), PriorityContext(snoozed: FollowUps.snoozed(list, now: now), now: now))
        XCTAssertEqual(hidden.muted, .snoozed)
        XCTAssertLessThan(hidden.score, 30)

        let later = date(2026, 10, 24, 10)
        XCTAssertTrue(FollowUps.snoozed(list, now: later).isEmpty)
        XCTAssertEqual(FollowUps.resurfaced(list, now: later), ["m1"])
        let back = Priority.score(msg(unread: true), PriorityContext(resurfaced: FollowUps.resurfaced(list, now: later), now: later))
        XCTAssertNil(back.muted)
        XCTAssertGreaterThanOrEqual(back.score, Stacker.priorityThreshold)
        XCTAssertTrue(back.reasons.contains("back from snooze"))
    }

    func testSnoozeBeatsFavourite() {
        let s = Priority.score(msg(), PriorityContext(favourites: ["maya@acme.example"], snoozed: ["m1": Date().addingTimeInterval(3600)]))
        XCTAssertEqual(s.muted, .snoozed)
    }

    func testAddReplacesInsteadOfStacking() {
        var list: [FollowUp] = []
        FollowUps.add(FollowUp(kind: .snooze, message: msg(), due: date(2026, 10, 25)), to: &list)
        FollowUps.add(FollowUp(kind: .snooze, message: msg(), due: date(2026, 10, 27)), to: &list)
        FollowUps.add(FollowUp(kind: .awaitingReply, message: msg("m2"), due: date(2026, 10, 26)), to: &list)   // same thread, other kind
        FollowUps.add(FollowUp(kind: .awaitingReply, message: msg("m3"), due: date(2026, 10, 28)), to: &list)   // same thread again
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.due), [date(2026, 10, 27), date(2026, 10, 28)])
    }

    func testDueWaitingAndWake() {
        let now = date(2026, 10, 23)
        var a = FollowUp(kind: .awaitingReply, message: msg("a", thread: "ta"), due: date(2026, 10, 22))
        let b = FollowUp(kind: .snooze, message: msg("b", thread: "tb"), due: date(2026, 10, 30))
        XCTAssertEqual(FollowUps.due([a, b], now: now).map(\.message.id), ["a"])
        XCTAssertEqual(FollowUps.waiting([a, b], now: now).map(\.message.id), ["b"])
        XCTAssertEqual(FollowUps.toAnnounce([a, b], now: now).map(\.message.id), ["a"])
        XCTAssertEqual(FollowUps.nextWake([a, b]), a.due)
        a.notified = true
        XCTAssertTrue(FollowUps.toAnnounce([a, b], now: now).isEmpty)
        XCTAssertEqual(FollowUps.nextWake([a, b]), b.due)
        XCTAssertNil(FollowUps.nextWake([a]))
    }

    func testPresetsOnAFridayMorning() {
        let p = FollowUps.presets(now: date(2026, 10, 23, 10), calendar: cal)
        XCTAssertEqual(p.map(\.label), ["Later today", "Tomorrow morning", "Next week"])   // Friday: the weekend is tomorrow, so no duplicate
        XCTAssertEqual(p[0].date, date(2026, 10, 23, 18))
        XCTAssertEqual(p[1].date, date(2026, 10, 24, 9))
        XCTAssertEqual(p[2].date, date(2026, 10, 26, 9))   // Monday
    }

    func testPresetsOnAWednesdayEvening() {
        let p = FollowUps.presets(now: date(2026, 10, 21, 17), calendar: cal)
        XCTAssertEqual(p.map(\.label), ["Tomorrow morning", "This weekend", "Next week"])
        XCTAssertEqual(p[1].date, date(2026, 10, 24, 9))
        XCTAssertEqual(p[2].date, date(2026, 10, 26, 9))
        XCTAssertTrue(FollowUps.presets(now: date(2026, 10, 25, 11), calendar: cal).allSatisfy { $0.date > date(2026, 10, 25, 11) })   // Sunday
    }

    func testDueAfterDaysIsNineInTheMorning() {
        XCTAssertEqual(FollowUps.dueAfter(days: 3, now: date(2026, 10, 23, 15), calendar: cal), date(2026, 10, 26, 9))
        XCTAssertEqual(FollowUps.dueAfter(days: 0, now: date(2026, 10, 23, 15), calendar: cal), date(2026, 10, 24, 9))
    }

    func testWhenForAgents() {
        let now = date(2026, 10, 23)
        XCTAssertEqual(FollowUps.when(until: nil, days: 2, hours: 3, now: now), now.addingTimeInterval(2 * 86400 + 3 * 3600))
        XCTAssertEqual(FollowUps.when(until: "2026-11-02T09:00:00Z", days: nil, hours: nil, now: now), date(2026, 11, 2, 9))
        XCTAssertNotNil(FollowUps.when(until: "2026-11-02T09:00:00.000Z", days: nil, hours: nil, now: now))
        XCTAssertNotNil(FollowUps.when(until: "2026-11-02", days: nil, hours: nil, now: now))
        XCTAssertNil(FollowUps.when(until: "2026-10-01T09:00:00Z", days: nil, hours: nil, now: now), "the past is not a reminder")
        XCTAssertNil(FollowUps.when(until: "next tuesday", days: nil, hours: nil, now: now))
        XCTAssertNil(FollowUps.when(until: nil, days: nil, hours: nil, now: now))
    }

    func thread(_ messages: [(from: String, ms: Double, labels: [String])]) -> [String: Any] {
        ["messages": messages.map { ["internalDate": String(Int($0.ms)), "labelIds": $0.labels, "payload": ["headers": [["name": "From", "value": $0.from]]]] as [String: Any] }]
    }

    func testReplyDetection() {
        let since = date(2026, 10, 23)
        let t = since.timeIntervalSince1970 * 1000
        // Only me, and an older message from them: no reply.
        XCTAssertFalse(FollowUps.hasReply(in: thread([("Maya <maya@acme.example>", t - 5000, ["INBOX"]), ("me@gmail.com", t + 1000, ["SENT"])]), account: "me@gmail.com", since: since))
        // Someone else wrote afterwards.
        XCTAssertTrue(FollowUps.hasReply(in: thread([("me@gmail.com", t + 1000, ["SENT"]), ("Maya <maya@acme.example>", t + 90_000, ["INBOX", "UNREAD"])]), account: "me@gmail.com", since: since))
        // My own address in another case, or with a name, is still me.
        XCTAssertFalse(FollowUps.hasReply(in: thread([("Me <ME@Gmail.com>", t + 1000, [])]), account: "me@gmail.com", since: since))
        // A draft is not a reply.
        XCTAssertFalse(FollowUps.hasReply(in: thread([("Maya <maya@acme.example>", t + 1000, ["DRAFT"])]), account: "me@gmail.com", since: since))
        XCTAssertFalse(FollowUps.hasReply(in: [:], account: "me@gmail.com", since: since))
    }

    func testFollowUpsSurviveSavingAndOldFilesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moose-fu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DataStore(file: dir.appendingPathComponent("moose.json"))
        var d = MooseData()
        FollowUps.add(FollowUp(kind: .awaitingReply, message: msg(), created: date(2026, 10, 23), due: date(2026, 10, 26, 9)), to: &d.followUps)
        try store.save(d)
        let back = store.load()
        XCTAssertEqual(back.followUps.count, 1)
        XCTAssertEqual(back.followUps.first?.kind, .awaitingReply)
        XCTAssertEqual(back.followUps.first?.message.subject, "Contract")
        // A file from before follow-ups existed has no such key.
        try Data(#"{"version":1,"accounts":[]}"#.utf8).write(to: dir.appendingPathComponent("moose.json"))
        XCTAssertEqual(store.load().followUps, [])
    }

    func testSnoozedMessagesLandInMutedView() {
        let m = msg()
        let scored = Priority.scoreAll([m], PriorityContext(snoozed: [m.id: Date().addingTimeInterval(3600)]))
        XCTAssertTrue(Stacker.stacks(for: .priority, messages: scored, favourites: []).isEmpty)
        XCTAssertEqual(Stacker.stacks(for: .muted, messages: scored, favourites: []).count, 1)
    }

    func testDescribe() {
        let now = date(2026, 10, 23, 10)
        XCTAssertTrue(FollowUps.describe(date(2026, 10, 23, 18), now: now, calendar: cal).hasPrefix("today"))
        XCTAssertTrue(FollowUps.describe(date(2026, 10, 24, 9), now: now, calendar: cal).hasPrefix("tomorrow"))
    }
}
