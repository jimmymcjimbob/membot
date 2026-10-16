import Foundation
import Testing
@testable import MemBotCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func snap(_ t: Date, _ ps: [ProcessSample]) -> Snapshot {
  Snapshot(time: t, system: SystemSample(memUsed: 0, memTotal: 0, swapUsed: 0, cpuPercent: 0),
           processes: Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) }))
}

@Test func historyTrims() {
  var h = History()
  let p = proc(5, ppid: 1, name: "x", footprint: 7)
  for dt in [0.0, 300, 601] { h.append(snap(t0.addingTimeInterval(dt), [p]), cpuPercent: [5: 2]) }
  let pts = h.points(p.key)
  #expect(pts.count == 2)
  #expect(pts.first?.time == t0.addingTimeInterval(300))
  #expect(pts.last?.footprint == 7 && pts.last?.cpuPercent == 2)
}

@Test func historyDropsEndedProcess() {
  var h = History()
  let p = proc(5, ppid: 1, name: "x")
  h.append(snap(t0, [p]), cpuPercent: [:])
  h.append(snap(t0.addingTimeInterval(1), [proc(6, ppid: 1, name: "y")]), cpuPercent: [:])
  #expect(h.points(p.key).isEmpty)
}

private let ps = [
  proc(2407, ppid: 1, name: "ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", footprint: 10),
  proc(6912, ppid: 2407, name: "login", path: "/usr/bin/login", footprint: 1),
  proc(7000, ppid: 6912, name: "-zsh", footprint: 2),
  proc(62480, ppid: 7000, name: "claude", footprint: 100, cwd: "/Users/james/Code/membot"),
  proc(94987, ppid: 62480, name: "node", footprint: 20),
  proc(95000, ppid: 94987, name: "sh", footprint: 3),
  proc(95001, ppid: 95000, name: "git", footprint: 4),
  proc(94988, ppid: 62480, name: "python", footprint: 5),
  proc(71123, ppid: 7000, name: "codex", footprint: 50),
  proc(30925, ppid: 1, name: "node", path: "/Users/james/.nvm/bin/node", footprint: 30,
       sockets: [SocketInfo(proto: .tcp, localAddress: "::", localPort: 5173, remoteAddress: nil, remotePort: nil, isListening: true)]),
]
private let forest = buildForest(
  TreeInput(processes: Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) }), cpuPercent: [:], ownerUID: 501,
            terminalHosts: Set(MemBotSettings().terminalHosts), launchdJobPIDs: [600]), memory: RootMemory())
private let ai = MemBotSettings().aiToolNames
private func filter(_ q: String, _ m: FilterMode = .all, _ c: Set<Int32> = []) -> [RootGroup] {
  filterForest(forest, query: q, mode: m, candidatePIDs: c, aiToolNames: ai)
}
private func pids(_ n: ProcessNode) -> Set<Int32> { Set([n.pid]).union(n.children.flatMap { pids($0) }) }

@Test func searchByPort() {
  let r = filter("5173")
  #expect(r.map(\.name) == ["node"] && r[0].kind == .orphan)
}

@Test func searchByFolderKeepsGroup() throws {
  let r = filter("membot")
  #expect(r.map(\.name) == ["claude"])
  #expect(pids(r[0].node) == [62480, 94987, 95000, 95001, 94988])
}

@Test func searchPrunesBranches() {
  let r = filter("git")
  #expect(r.map(\.name) == ["claude"])
  #expect(pids(r[0].node) == [62480, 94987, 95000, 95001])
  #expect(r[0].node.totalFootprint == 132) // totals stay real
}

@Test func candidatesMode() {
  #expect(filter("", .candidates, [30925]).map(\.name) == ["node"])
}

@Test func aiToolsMode() {
  #expect(Set(filter("", .aiTools).map(\.name)) == ["claude", "codex"])
}
