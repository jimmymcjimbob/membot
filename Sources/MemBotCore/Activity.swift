import Foundation

public enum ProcessStatus: Equatable, Sendable { case active, idle(since: Date), candidate(since: Date) }

/// CPU % per pid: the `top` value when the sample has one, else the delta between two snapshots.
public func processCPUPercents(previous: Snapshot?, current: Snapshot) -> [Int32: Double] {
  var out: [Int32: Double] = [:]
  let wall = previous.map { current.time.timeIntervalSince($0.time) } ?? 0
  for (pid, s) in current.processes {
    if let top = s.cpuPercent { out[pid] = top; continue }
    guard wall > 0, let p = previous?.processes[pid], p.key == s.key,
          let a = p.cpuTimeNs, let b = s.cpuTimeNs else { continue }
    out[pid] = Double(b.saturatingSub(a)) / (wall * 1e9) * 100
  }
  return out
}

extension UInt64 {
  /// Counters can go backwards (pid reuse that slipped through); a negative delta is 0.
  fileprivate func saturatingSub(_ o: UInt64) -> UInt64 { self >= o ? self - o : 0 }
}

public struct ActivityTracker: Sendable {
  private struct Bucket {
    var start: Date
    var cpuNs: UInt64?
    var disk: UInt64?
    var sockets: Set<SocketInfo>?
    var maxTop = 0.0
  }
  private struct Entry { var lastActive: Date; var bucket: Bucket }

  private var entries: [ProcessKey: Entry] = [:]
  private var lastIngest: Date?
  public private(set) var clockStart: Date?
  private static let bucketSeconds: TimeInterval = 60
  private static let sleepGap: TimeInterval = 120

  public init() {}

  public func lastActive(_ key: ProcessKey) -> Date? { entries[key]?.lastActive }

  public mutating func ingest(_ snapshot: Snapshot, cpuPercent: [Int32: Double], settings: MemBotSettings) {
    let now = snapshot.time
    if clockStart == nil || lastIngest.map({ now.timeIntervalSince($0) > Self.sleepGap }) == true {
      entries = [:]
      clockStart = now
    }
    lastIngest = now
    var next: [ProcessKey: Entry] = [:]
    for s in snapshot.processes.values {
      let top = s.cpuPercent ?? 0
      guard var e = entries[s.key] else {
        next[s.key] = Entry(lastActive: now, bucket: Self.bucket(s, now))
        continue
      }
      e.bucket.maxTop = max(e.bucket.maxTop, top)
      let span = now.timeIntervalSince(e.bucket.start)
      if span >= Self.bucketSeconds {
        if Self.isActive(e.bucket, s, span: span, settings: settings) { e.lastActive = now }
        e.bucket = Self.bucket(s, now)
      }
      next[s.key] = e
    }
    entries = next
  }

  private static func bucket(_ s: ProcessSample, _ now: Date) -> Bucket {
    Bucket(start: now, cpuNs: s.cpuTimeNs, disk: s.diskBytes, sockets: s.sockets.map(Set.init))
  }

  private static func isActive(_ b: Bucket, _ s: ProcessSample, span: TimeInterval, settings: MemBotSettings) -> Bool {
    if b.maxTop >= settings.cpuActivePercent { return true }
    if let a = b.cpuNs, let c = s.cpuTimeNs,
       Double(c.saturatingSub(a)) / (span * 1e9) * 100 >= settings.cpuActivePercent { return true }
    if let a = b.disk, let c = s.diskBytes, c.saturatingSub(a) > settings.diskActiveBytes { return true }
    if let a = b.sockets, let c = s.sockets, a != Set(c) { return true }
    return false
  }
}
