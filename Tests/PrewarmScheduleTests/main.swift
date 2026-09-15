// Standalone tests for PrewarmSchedule — the pre-warm scheduling rules.
//
// These are entirely about wall-clock edge cases (sleeping through the fire
// time, weekends, running twice in a day), so they must be testable without
// waiting for 8am to come around. PrewarmSchedule takes `now` and a Calendar as
// parameters for exactly that reason, and depends on nothing but Foundation —
// which is why this needs no test target:
//
//   swiftc -o /tmp/prewarm-tests \
//       CCSwitcher/Services/PrewarmSchedule.swift \
//       Tests/PrewarmScheduleTests/main.swift
//   /tmp/prewarm-tests

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool) {
    if actual == expected { print("  ok   \(label)") }
    else { print("  FAIL \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

// Pinned time zone, otherwise results drift with the machine's settings.
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!

func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func run(_ now: Date, last: String? = nil, weekdaysOnly: Bool = true) -> Bool {
    PrewarmSchedule.shouldRun(now: now, hour: 8, minute: 0,
                              weekdaysOnly: weekdaysOnly, lastRunDay: last, calendar: cal)
}

// 2026-09-15 is a Tuesday; 09-19 Saturday, 09-20 Sunday.
print("Firing:")
check("fires at 08:00",                       run(at(2026,9,15,8,0)),   true)
check("does not fire at 07:59",               run(at(2026,9,15,7,59)),  false)
check("catches up at 08:30",                  run(at(2026,9,15,8,30)),  true)

print("Idempotence (once per day):")
check("already warmed today — skipped",       run(at(2026,9,15,9,0), last: "2026-09-15"), false)
check("warmed yesterday — runs again",        run(at(2026,9,15,9,0), last: "2026-09-14"), true)

print("Catch-up window (3h):")
check("10:59 still inside the window",        run(at(2026,9,15,10,59)), true)
check("11:01 past it — today written off",    run(at(2026,9,15,11,1)),  false)
check("23:00 wake never warms",               run(at(2026,9,15,23,0)),  false)

print("Weekends:")
check("Saturday skipped",                     run(at(2026,9,19,8,0)),   false)
check("Sunday skipped",                       run(at(2026,9,20,8,0)),   false)
check("Saturday runs when weekdaysOnly off",  run(at(2026,9,19,8,0), weekdaysOnly: false), true)

print("Day stamp:")
let stamp = PrewarmSchedule.dayStamp(at(2026,9,5,8,0), calendar: cal)
check("zero-padded 2026-09-05", stamp == "2026-09-05", true)
if stamp != "2026-09-05" { print("       got \(stamp)") }

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
