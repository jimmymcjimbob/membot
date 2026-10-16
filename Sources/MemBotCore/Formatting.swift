import Foundation

public func formatBytes(_ bytes: UInt64) -> String {
  let b = Double(bytes)
  if bytes >= 1 << 30 { return String(format: "%.1f GB", b / Double(1 << 30)) }
  if bytes >= 1 << 20 { return String(format: "%.0f MB", b / Double(1 << 20)) }
  return String(format: "%.0f KB", b / 1024)
}

public func formatDuration(_ seconds: TimeInterval) -> String {
  let m = Int(seconds / 60)
  let (h, r) = m.quotientAndRemainder(dividingBy: 60)
  if h == 0 { return "\(r) min" }
  return r == 0 ? "\(h) h" : "\(h) h \(r) min"
}

public func memoryLine(_ s: SystemSample) -> String {
  let gib = Double(1 << 30)
  let pct = s.memTotal == 0 ? 0 : Double(s.memUsed) / Double(s.memTotal) * 100
  var line = String(format: "%.1f / %.0f GB · %.0f%%", Double(s.memUsed) / gib, Double(s.memTotal) / gib, pct)
  if s.swapUsed > 0 { line += " · swap \(formatBytes(s.swapUsed))" }
  return line
}

public enum UsageLevel: Sendable { case ok, warn, crit }

public func usageLevel(_ percent: Double, warnAt: Double, critAt: Double) -> UsageLevel {
  percent > critAt ? .crit : percent >= warnAt ? .warn : .ok
}

public func cpuPercent(from a: CPUTicks, to b: CPUTicks) -> Double {
  let busy = (b.user - a.user) + (b.system - a.system) + (b.nice - a.nice)
  let total = busy + (b.idle - a.idle)
  return total == 0 ? 0 : Double(busy) / Double(total) * 100
}
