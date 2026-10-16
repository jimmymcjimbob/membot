import Foundation
import Testing
@testable import MemBotCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
private let sys = SystemSample(memUsed: 0, memTotal: 0, swapUsed: 0, cpuPercent: 0)

private func snap(_ t: TimeInterval, _ ps: [ProcessSample]) -> Snapshot {
  Snapshot(time: t0.addingTimeInterval(t), system: sys, processes: Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) }))
}

private func forest(_ ps: [ProcessSample]) -> [RootGroup] {
  buildForest(TreeInput(processes: Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) }), cpuPercent: [:], ownerUID: 501,
                        terminalHosts: Set(MemBotSettings().terminalHosts), launchdJobPIDs: [600]), memory: RootMemory())
}

/// Ingest every 5 s from `from` to `to` inclusive; `make` builds the processes for each time.
private func run(_ tr: inout ActivityTracker, _ from: TimeInterval, _ to: TimeInterval, _ make: (TimeInterval) -> [ProcessSample]) {
  for t in stride(from: from, through: to, by: 5) { tr.ingest(snap(t, make(t)), cpuPercent: [:], settings: MemBotSettings()) }
}

private func eval(_ gs: [RootGroup], _ tr: ActivityTracker, at t: TimeInterval) -> Evaluation {
  evaluate(gs, tracker: tr, settings: MemBotSettings(), ownerUID: 501, now: t0.addingTimeInterval(t))
}

private let terminal = [
  proc(2407, ppid: 1, name: "ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", footprint: 10),
  proc(6912, ppid: 2407, name: "login", path: "/usr/bin/login", footprint: 1),
  proc(7000, ppid: 6912, name: "-zsh", footprint: 2),
  proc(62480, ppid: 7000, name: "claude", footprint: 100),
  proc(94987, ppid: 62480, name: "node", footprint: 20),
  proc(95000, ppid: 94987, name: "sh", footprint: 3),
  proc(95001, ppid: 95000, name: "git", footprint: 4),
]

private func listen(_ port: UInt16) -> SocketInfo {
  SocketInfo(proto: .tcp, localAddress: "*", localPort: port, remoteAddress: nil, remotePort: nil, isListening: true)
}

@Test func idleClockStartsAtFirstSample() {
  let ps = [proc(10, ppid: 1, name: "a", path: "/Applications/A.app/a")]
  let gs = forest(ps)
  var tr = ActivityTracker()
  run(&tr, 0, 60) { _ in ps }
  #expect(eval(gs, tr, at: 60).statuses[10] == .active)
  run(&tr, 65, 120) { _ in ps }
  #expect(eval(gs, tr, at: 120).statuses[10] == .idle(since: t0))
}

@Test func cpuKeepsActive() {
  func ps(_ t: TimeInterval) -> [ProcessSample] { terminal.map { $0.pid == 95001 ? proc(95001, ppid: 95000, name: "git", cpuTimeNs: UInt64(t / 60 * 600_000_000)) : $0 } }
  var tr = ActivityTracker()
  run(&tr, 0, 1200, ps)
  let e = eval(forest(ps(1200)), tr, at: 1200)
  #expect(e.statuses[94987] == .active)
  #expect(e.candidates.isEmpty)
}

@Test func aiSessionBecomesOneCandidate() throws {
  var tr = ActivityTracker()
  run(&tr, 0, 900) { _ in terminal }
  let gs = forest(terminal)
  let e = eval(gs, tr, at: 900)
  #expect(e.candidates.count == 1)
  let c = try #require(e.candidates.first)
  #expect(c.key.pid == 62480)
  #expect(c.totalFootprint == gs.first { $0.name == "claude" }!.node.totalFootprint)
  #expect(c.reasons.contains("children idle"))
  #expect(c.rootName == "claude" && !c.isOrphan)
  guard case .idle = e.statuses[94987] else { Issue.record("not idle"); return }
  #expect(e.statuses[62480] == .candidate(since: t0))
}

@Test func orphanAfterFiveMinutes() throws {
  let ps = [proc(30925, ppid: 1, name: "node", path: "/Users/james/bin/node", sockets: [listen(5173)])]
  var tr = ActivityTracker()
  run(&tr, 0, 300) { _ in ps }
  let c = try #require(eval(forest(ps), tr, at: 300).candidates.first)
  #expect(c.reasons == ["parent gone", "CPU below 0.5% for 5 min", "no network or disk activity", "listens on 5173, no connections"])
  #expect(c.shortReason == "parent gone · CPU below 0.5% for 5 min")
}

@Test func nonAIAppIsNeverCandidate() {
  let ps = [proc(1, ppid: 0, name: "launchd"), proc(56021, ppid: 1, name: "Brave Browser", path: brave)]
  var tr = ActivityTracker()
  run(&tr, 0, 1800) { _ in ps }
  #expect(eval(forest(ps), tr, at: 1800).candidates.isEmpty)
}

@Test func otherUserNeverCandidate() {
  let root = proc(40, ppid: 1, name: "node", uid: 0)
  let node = ProcessNode(pid: 40, sample: root, children: [], totalFootprint: 0, totalCPUPercent: 0, descendantCount: 0)
  let g = RootGroup(kind: .orphan, name: "node", cwd: nil, node: node, lastKnownRoot: nil)
  var tr = ActivityTracker()
  run(&tr, 0, 600) { _ in [root] }
  #expect(eval([g], tr, at: 600).candidates.isEmpty)

  // top-only sample: no cpuTimeNs, cpuPercent 3.0
  let top = ProcessSample(key: ProcessKey(pid: 41, startTime: 1), ppid: 1, uid: 501, name: "node", path: "/x/node", cpuPercent: 3.0)
  let g2 = RootGroup(kind: .orphan, name: "node", cwd: nil,
                     node: ProcessNode(pid: 41, sample: top, children: [], totalFootprint: 0, totalCPUPercent: 0, descendantCount: 0),
                     lastKnownRoot: nil)
  var tr2 = ActivityTracker()
  run(&tr2, 0, 600) { _ in [top] }
  let e = eval([g2], tr2, at: 600)
  #expect(e.statuses[41] == .active)
  #expect(e.candidates.isEmpty)
}

@Test func activeChildBlocksParent() {
  func ps(_ t: TimeInterval) -> [ProcessSample] {
    terminal.map { $0.pid == 95001 ? proc(95001, ppid: 95000, name: "git", cpuTimeNs: UInt64(t / 60 * 600_000_000)) : $0 }
  }
  var tr = ActivityTracker()
  run(&tr, 0, 900, ps)
  let e = eval(forest(ps(900)), tr, at: 900)
  #expect(!e.candidates.contains { $0.key.pid == 62480 })
  #expect(e.statuses[62480] == .active)
}

@Test func idleSiblingSubtreeIsCandidate() {
  // 94987 subtree is busy (via 95001); a second child 96000 is idle.
  let all = terminal + [proc(96000, ppid: 62480, name: "node", footprint: 7)]
  func ps(_ t: TimeInterval) -> [ProcessSample] {
    all.map { $0.pid == 95001 ? proc(95001, ppid: 95000, name: "git", cpuTimeNs: UInt64(t / 60 * 600_000_000)) : $0 }
  }
  var tr = ActivityTracker()
  run(&tr, 0, 900, ps)
  let e = eval(forest(ps(900)), tr, at: 900)
  #expect(e.candidates.map(\.key.pid) == [96000])
}

@Test func sleepGapResetsClock() {
  var tr = ActivityTracker()
  run(&tr, 0, 600) { _ in terminal }
  tr.ingest(snap(4200, terminal), cpuPercent: [:], settings: MemBotSettings())
  let e = eval(forest(terminal), tr, at: 4200)
  #expect(e.candidates.isEmpty)
  #expect(tr.clockStart == t0.addingTimeInterval(4200))
  #expect(e.warmup?.elapsed == 0)
}

@Test func warmupCountsUp() {
  var tr = ActivityTracker()
  run(&tr, 0, 180) { _ in terminal }
  let w = eval(forest(terminal), tr, at: 180).warmup
  #expect(w?.elapsed == 180 && w?.needed == 900)
  #expect(eval(forest(terminal), tr, at: 900).warmup == nil)
}

@Test func backwardsCountersDoNotTrap() {
  var tr = ActivityTracker()
  run(&tr, 0, 60) { t in [proc(10, ppid: 1, name: "a", cpuTimeNs: t < 30 ? 9_000_000_000 : 1, diskBytes: t < 30 ? 9_000 : 1)] }
}

@Test func cpuPercents() {
  let a = proc(10, ppid: 1, name: "a", cpuTimeNs: 1_000_000_000)
  let b = proc(10, ppid: 1, name: "a", cpuTimeNs: 1_500_000_000)
  let reused = proc(11, ppid: 1, name: "b", cpuTimeNs: 5, start: 2)
  let before = proc(11, ppid: 1, name: "b", cpuTimeNs: 0, start: 1)
  let r = processCPUPercents(previous: snap(0, [a, before]), current: snap(1, [b, reused]))
  #expect(r[10] == 50)
  #expect(r[11] == nil)
}

@Test func shortBurstsBelowMinuteAverageStayIdle() {
  // 100 ms of CPU in one 5 s window per minute: 2% in that window, 0.17% over the minute.
  func ps(_ t: TimeInterval) -> [ProcessSample] {
    let ns = UInt64((t / 60).rounded(.down)) * 100_000_000 + (Int(t) % 60 >= 55 ? 100_000_000 : 0)
    return terminal.map { $0.pid == 95001 ? proc(95001, ppid: 95000, name: "git", cpuTimeNs: ns) : $0 }
  }
  var tr = ActivityTracker()
  var prev: Snapshot?
  for t in stride(from: 0.0, through: 900, by: 5) {
    let s = snap(t, ps(t))
    tr.ingest(s, cpuPercent: processCPUPercents(previous: prev, current: s), settings: MemBotSettings())
    prev = s
  }
  #expect(eval(forest(ps(900)), tr, at: 900).candidates.map(\.key.pid) == [62480])
}

@Test func equalFootprintCandidatesInPIDOrder() {
  let ps = (0..<6).map { proc(30920 + Int32($0), ppid: 1, name: "node", path: "/Users/james/bin/node", footprint: 7) }
  var tr = ActivityTracker()
  run(&tr, 0, 300) { _ in ps }
  let gs = forest(ps)
  for order in [gs, gs.reversed(), gs.shuffled()] {
    #expect(eval(order, tr, at: 300).candidates.map(\.key.pid) == ps.map(\.pid))
  }
}
