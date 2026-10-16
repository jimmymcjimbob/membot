import Foundation

public struct Candidate: Identifiable, Sendable {
  public let key: ProcessKey
  public let name: String
  public let rootName: String
  public let totalFootprint: UInt64
  public let idleSince: Date
  public let isOrphan: Bool
  public let reasons: [String]
  public var id: ProcessKey { key }
  public var shortReason: String { reasons.prefix(2).joined(separator: " · ") }
  public init(key: ProcessKey, name: String, rootName: String, totalFootprint: UInt64, idleSince: Date,
              isOrphan: Bool, reasons: [String]) {
    self.key = key; self.name = name; self.rootName = rootName; self.totalFootprint = totalFootprint
    self.idleSince = idleSince; self.isOrphan = isOrphan; self.reasons = reasons
  }
}

public struct Evaluation: Sendable {
  public var statuses: [Int32: ProcessStatus]
  public var candidates: [Candidate]
  public var warmup: (elapsed: TimeInterval, needed: TimeInterval)?
  public init(statuses: [Int32: ProcessStatus], candidates: [Candidate], warmup: (elapsed: TimeInterval, needed: TimeInterval)?) {
    self.statuses = statuses; self.candidates = candidates; self.warmup = warmup
  }
}

/// One bucket plus the 5 s cadence and slack.
private let activeWindow: TimeInterval = 75

public func evaluate(_ groups: [RootGroup], tracker: ActivityTracker, settings: MemBotSettings,
                     ownerUID: UInt32, now: Date) -> Evaluation {
  var statuses: [Int32: ProcessStatus] = [:]
  var effective: [Int32: Date] = [:]

  func fill(_ n: ProcessNode) -> Date? {
    let latest = ([n.sample.flatMap { tracker.lastActive($0.key) }] + n.children.map(fill)).compactMap { $0 }.max()
    if n.sample != nil {
      let eff = latest ?? now
      effective[n.pid] = eff
      statuses[n.pid] = now.timeIntervalSince(eff) < activeWindow ? .active : .idle(since: eff)
    }
    return latest
  }
  groups.forEach { _ = fill($0.node) }

  var candidates: [Candidate] = []
  for g in groups where g.kind == .orphan || isAITool(g, names: settings.aiToolNames) {
    let isOrphan = g.kind == .orphan
    let limit = TimeInterval((isOrphan ? settings.orphanIdleMinutes : settings.candidateIdleMinutes) * 60)
    func walk(_ n: ProcessNode) {
      if let s = n.sample, s.uid == ownerUID, let eff = effective[n.pid], now.timeIntervalSince(eff) >= limit {
        statuses[n.pid] = .candidate(since: eff)
        candidates.append(Candidate(key: s.key, name: s.name, rootName: g.name, totalFootprint: n.totalFootprint,
                                    idleSince: eff, isOrphan: isOrphan,
                                    reasons: reasons(n, s, g, idle: now.timeIntervalSince(eff), settings)))
        return
      }
      n.children.forEach(walk)
    }
    walk(g.node)
  }
  candidates.sort { $0.totalFootprint > $1.totalFootprint }

  let needed = TimeInterval(settings.candidateIdleMinutes * 60)
  let elapsed = tracker.clockStart.map { now.timeIntervalSince($0) } ?? 0
  return Evaluation(statuses: statuses, candidates: candidates, warmup: elapsed < needed ? (elapsed, needed) : nil)
}

private func reasons(_ n: ProcessNode, _ s: ProcessSample, _ g: RootGroup, idle: TimeInterval,
                     _ settings: MemBotSettings) -> [String] {
  var r: [String] = []
  if g.kind == .orphan {
    r.append("parent gone")
    if let root = g.lastKnownRoot { r.append("was under \(root)") }
  }
  r.append("CPU below \(String(format: "%g", settings.cpuActivePercent))% for \(formatDuration(idle))")
  if s.diskBytes != nil, s.sockets != nil { r.append("no network or disk activity") }
  if !n.children.isEmpty { r.append("children idle") }
  let socks = s.sockets ?? []
  let connected = Set(socks.filter { !$0.isListening }.map(\.localPort))
  let ports = Set(socks.filter { $0.isListening && !connected.contains($0.localPort) }.map(\.localPort)).sorted()
  r += ports.map { "listens on \($0), no connections" }
  return r
}
