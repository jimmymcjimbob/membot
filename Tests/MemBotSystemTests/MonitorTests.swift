import Foundation
import Testing
@testable import MemBotCore
@testable import MemBotSystem

/// Lock-guarded value shared with the `@Sendable` fake sources (clock, call counters).
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

private let owner: UInt32 = 501
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let launchd = ProcessSample(key: ProcessKey(pid: 1, startTime: 1), ppid: 0, uid: 0, name: "launchd", path: "/sbin/launchd")
private let node = ProcessSample(key: ProcessKey(pid: 30925, startTime: 2), ppid: 1, uid: owner, name: "node",
                                 path: "/opt/homebrew/bin/node", footprint: 200 << 20, cpuTimeNs: 1_000_000, diskBytes: 0)

private func fakeSources(_ processes: [ProcessSample], top: [Int32: TopRow]? = [:], launchdJobs: Set<Int32>? = [],
                         argumentCalls: Locked<Int> = Locked(0)) -> MonitorSources {
  MonitorSources(
    processes: { processes },
    arguments: { _ in argumentCalls.value += 1; return ["node", "server.js"] },
    cwd: { _ in "/tmp" },
    sockets: { _ in [] },
    system: { SystemRaw(memUsed: 8 << 30, memTotal: 16 << 30, swapUsed: 0, ticks: CPUTicks(user: 0, system: 0, idle: 0, nice: 0)) },
    top: { top },
    launchdJobs: { launchdJobs })
}

/// Ticks `count` times, `every` seconds apart from `t0`, letting background work finish between ticks.
private func run(_ sources: MonitorSources, count: Int, every: TimeInterval = 5) async -> (Monitor, MonitorState) {
  let clock = Locked(t0)
  let monitor = Monitor(sources: sources, settings: MemBotSettings(), ownerUID: owner, now: { clock.value })
  await monitor.setVisible(true)
  var state = await monitor.tick()
  for _ in 1..<count {
    await monitor.awaitBackgroundWork()
    clock.value += every
    state = await monitor.tick()
  }
  return (monitor, state)
}

@Suite struct MonitorTests {
  @Test func orphanBecomesCandidate() async {
    let (_, state) = await run(fakeSources([launchd, node]), count: 61) // t0 ... t0 + 5 min
    #expect(state.evaluation.candidates.map(\.key.pid) == [30925])
  }

  @Test func topFillsOtherUsers() async {
    let other = ProcessSample(key: ProcessKey(pid: 88, startTime: 3), ppid: 1, uid: 0, name: "mds", path: "/System/mds")
    let sources = fakeSources([launchd, other], top: [88: TopRow(footprint: 500, cpuPercent: 2)])
    let (_, first) = await run(sources, count: 1)
    #expect(first.snapshot.processes[88]?.footprint == nil)
    let (_, state) = await run(sources, count: 2, every: 6)
    #expect(state.snapshot.processes[88]?.footprint == 500)
    #expect(state.cpuPercent[88] == 2)
  }

  @Test func detailsReadOncePerKey() async {
    let calls = Locked(0)
    let (_, state) = await run(fakeSources([launchd, node], argumentCalls: calls), count: 5)
    #expect(calls.value == 1)
    #expect(state.snapshot.processes[30925]?.arguments == ["node", "server.js"])
  }

  @Test func launchctlNilIsConservative() async {
    let (_, state) = await run(fakeSources([launchd, node], launchdJobs: nil), count: 121) // 10 min
    let background = state.groups.first { $0.kind == .backgroundServices }
    #expect(background?.node.children.contains { $0.pid == 30925 } == true)
    #expect(state.evaluation.candidates.isEmpty)
  }

  @Test func historyForSelected() async {
    let (monitor, _) = await run(fakeSources([launchd, node]), count: 3)
    #expect(await monitor.history(node.key).count == 3)
  }

  @Test func topOnlyWhileVisible() async {
    let calls = Locked(0)
    var sources = fakeSources([launchd, node])
    sources.top = { calls.value += 1; return [:] }
    let clock = Locked(t0)
    let monitor = Monitor(sources: sources, settings: MemBotSettings(), ownerUID: owner, now: { clock.value })
    for _ in 0...4 { // t0 ... t0 + 20 s
      _ = await monitor.tick()
      await monitor.awaitBackgroundWork()
      clock.value += 5
    }
    #expect(calls.value == 0)
    await monitor.setVisible(true)
    _ = await monitor.tick()
    await monitor.awaitBackgroundWork()
    #expect(calls.value == 1)
  }
}
