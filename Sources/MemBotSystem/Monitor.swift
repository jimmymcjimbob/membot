import Foundation
import MemBotCore

/// Every OS read the monitor makes, so tests can swap in fakes.
public struct MonitorSources: Sendable {
  public var processes: @Sendable () -> [ProcessSample]
  public var arguments: @Sendable (Int32) -> [String]?
  public var cwd: @Sendable (Int32) -> String?
  public var sockets: @Sendable (Int32) -> [SocketInfo]?
  public var system: @Sendable () -> SystemRaw
  public var top: @Sendable () async -> [Int32: TopRow]?
  public var launchdJobs: @Sendable () async -> Set<Int32>?

  public init(processes: @escaping @Sendable () -> [ProcessSample],
              arguments: @escaping @Sendable (Int32) -> [String]?,
              cwd: @escaping @Sendable (Int32) -> String?,
              sockets: @escaping @Sendable (Int32) -> [SocketInfo]?,
              system: @escaping @Sendable () -> SystemRaw,
              top: @escaping @Sendable () async -> [Int32: TopRow]?,
              launchdJobs: @escaping @Sendable () async -> Set<Int32>?) {
    self.processes = processes; self.arguments = arguments; self.cwd = cwd; self.sockets = sockets
    self.system = system; self.top = top; self.launchdJobs = launchdJobs
  }

  public static let live = MonitorSources(
    processes: { SystemReader.listProcesses() }, arguments: { SystemReader.arguments($0) },
    cwd: { SystemReader.cwd($0) }, sockets: { SystemReader.sockets($0) }, system: { SystemReader.system() },
    top: { await Commands.top() }, launchdJobs: { await Commands.launchdJobs() })
}

public struct MonitorState: Sendable {
  public let snapshot: Snapshot
  public let groups: [RootGroup]
  public let evaluation: Evaluation
  public let cpuPercent: [Int32: Double]
  public init(snapshot: Snapshot, groups: [RootGroup], evaluation: Evaluation, cpuPercent: [Int32: Double]) {
    self.snapshot = snapshot; self.groups = groups; self.evaluation = evaluation; self.cpuPercent = cpuPercent
  }
}

/// Turns OS samples into the state the UI (and later the memory manager) shows. One `tick()` per sample.
public actor Monitor {
  private static let socketInterval: TimeInterval = 5
  private static let topInterval: TimeInterval = 5
  private static let launchdInterval: TimeInterval = 30

  private let sources: MonitorSources
  private var settings: MemBotSettings
  private let ownerUID: UInt32
  private let now: @Sendable () -> Date

  private var previous: Snapshot?
  private var previousTicks: CPUTicks?
  private var details: [ProcessKey: (arguments: [String]?, cwd: String?)] = [:]
  private var sockets: [ProcessKey: [SocketInfo]?] = [:]
  private var lastSocketRead: Date?
  // Only one task of each kind runs at a time, so an older run can never overwrite a newer result.
  private var topTask: Task<Void, Never>?
  private var topStarted: Date?
  private var topRows: [Int32: TopRow] = [:]
  private var visible = false
  private var launchdTask: Task<Void, Never>?
  private var launchdStarted: Date?
  private var launchdPIDs: Set<Int32>?
  private var tracker = ActivityTracker()
  private var memory = RootMemory()
  private var history = History()

  public init(sources: MonitorSources = .live, settings: MemBotSettings, ownerUID: UInt32 = getuid(),
              now: @escaping @Sendable () -> Date = { Date() }) {
    self.sources = sources; self.settings = settings; self.ownerUID = ownerUID; self.now = now
  }

  public func update(settings: MemBotSettings) { self.settings = settings }

  /// `top` costs ~1 s CPU per run and only feeds the display, so it runs only while a surface is visible.
  public func setVisible(_ visible: Bool) { self.visible = visible }

  public func history(_ key: ProcessKey) -> [HistoryPoint] { history.points(key) }

  /// Waits for running `top`/`launchctl` tasks; lets tests make their results visible to the next tick.
  func awaitBackgroundWork() async {
    await topTask?.value
    await launchdTask?.value
  }

  public func tick() async -> MonitorState {
    let time = now()
    let raw = sources.system()
    let systemCPU = previousTicks.map { busyPercent(from: $0, to: raw.ticks) } ?? 0
    previousTicks = raw.ticks
    let readSockets = lastSocketRead.map { time.timeIntervalSince($0) >= Self.socketInterval } ?? true
    if readSockets { lastSocketRead = time }
    startBackgroundWork(time)

    var nextDetails: [ProcessKey: (arguments: [String]?, cwd: String?)] = [:]
    var nextSockets: [ProcessKey: [SocketInfo]?] = [:]
    var processes: [Int32: ProcessSample] = [:]
    for s in sources.processes() {
      var args: [String]?, cwd: String?, socks: [SocketInfo]?
      if s.uid == ownerUID {
        let d = details[s.key] ?? (sources.arguments(s.pid), sources.cwd(s.pid))
        nextDetails[s.key] = d
        (args, cwd) = d
        socks = readSockets ? sources.sockets(s.pid) : sockets[s.key] ?? nil
        nextSockets[s.key] = socks
      }
      let top = s.footprint == nil ? topRows[s.pid] : nil
      processes[s.pid] = ProcessSample(
        key: s.key, ppid: s.ppid, uid: s.uid, name: s.name, path: s.path,
        footprint: top?.footprint ?? s.footprint, cpuTimeNs: s.cpuTimeNs, cpuPercent: top?.cpuPercent ?? s.cpuPercent,
        diskBytes: s.diskBytes, sockets: socks, arguments: args, cwd: cwd)
    }
    details = nextDetails
    sockets = nextSockets

    let snapshot = Snapshot(time: time, system: SystemSample(memUsed: raw.memUsed, memTotal: raw.memTotal,
                                                             swapUsed: raw.swapUsed, cpuPercent: systemCPU),
                            processes: processes)
    let cpu = processCPUPercents(previous: previous, current: snapshot)
    previous = snapshot
    tracker.ingest(snapshot, cpuPercent: cpu, settings: settings)
    let groups = buildForest(TreeInput(processes: processes, cpuPercent: cpu, ownerUID: ownerUID,
                                       terminalHosts: Set(settings.terminalHosts), launchdJobPIDs: launchdPIDs),
                             memory: memory)
    memory.record(groups)
    history.append(snapshot, cpuPercent: cpu)
    let evaluation = evaluate(groups, tracker: tracker, settings: settings, ownerUID: ownerUID, now: time)
    return MonitorState(snapshot: snapshot, groups: groups, evaluation: evaluation, cpuPercent: cpu)
  }

  private func startBackgroundWork(_ time: Date) {
    if visible, topTask == nil, topStarted.map({ time.timeIntervalSince($0) >= Self.topInterval }) ?? true {
      topStarted = time
      topTask = Task {
        let rows = await sources.top()
        topRows = rows ?? [:] // a failed run fills nothing rather than leaving stale pids
        topTask = nil
      }
    }
    if launchdTask == nil, launchdStarted.map({ time.timeIntervalSince($0) >= Self.launchdInterval }) ?? true {
      launchdStarted = time
      launchdTask = Task {
        if let jobs = await sources.launchdJobs() { launchdPIDs = jobs }
        launchdTask = nil
      }
    }
  }
}

/// `cpuPercent(from:to:)`, but 0 when a counter went backwards (a failed read returns zeros), which would trap.
private func busyPercent(from a: CPUTicks, to b: CPUTicks) -> Double {
  guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return 0 }
  return cpuPercent(from: a, to: b)
}
