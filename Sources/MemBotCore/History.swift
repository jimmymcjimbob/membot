import Foundation

public struct HistoryPoint: Sendable, Equatable {
  public let time: Date
  public let footprint: UInt64
  public let cpuPercent: Double
  public init(time: Date, footprint: UInt64, cpuPercent: Double) {
    self.time = time; self.footprint = footprint; self.cpuPercent = cpuPercent
  }
}

public struct History: Sendable {
  private let window: TimeInterval
  private var series: [ProcessKey: [HistoryPoint]] = [:]
  public init(window: TimeInterval = 600) { self.window = window }

  public mutating func append(_ snapshot: Snapshot, cpuPercent: [Int32: Double]) {
    let cutoff = snapshot.time.addingTimeInterval(-window)
    var next: [ProcessKey: [HistoryPoint]] = [:]
    next.reserveCapacity(snapshot.processes.count)
    for p in snapshot.processes.values {
      var pts = series.removeValue(forKey: p.key) ?? [] // take ownership: avoids copy-on-write of the series
      // Series is time-ordered, so only the expired prefix needs dropping.
      if let first = pts.first, first.time < cutoff {
        pts.removeFirst(pts.prefix { $0.time < cutoff }.count)
      }
      pts.append(HistoryPoint(time: snapshot.time, footprint: p.footprint ?? 0, cpuPercent: cpuPercent[p.pid] ?? 0))
      next[p.key] = pts
    }
    series = next
  }

  public func points(_ key: ProcessKey) -> [HistoryPoint] { series[key] ?? [] }
}
