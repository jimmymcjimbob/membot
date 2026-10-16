import Foundation

/// Parses a `KERN_PROCARGS2` buffer: Int32 argc (LE), exec path, NUL padding, then argc C strings.
public func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
  guard bytes.count >= 4 else { return nil }
  let argc = Int(Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
  guard argc >= 0 else { return nil }
  var i = 4
  guard let pathEnd = bytes[i...].firstIndex(of: 0) else { return nil }
  i = pathEnd
  while i < bytes.count, bytes[i] == 0 { i += 1 }
  var args: [String] = []
  while args.count < argc {
    guard i < bytes.count, let end = bytes[i...].firstIndex(of: 0) else { return nil }
    args.append(String(decoding: bytes[i..<end], as: UTF8.self))
    i = end + 1
  }
  return args
}

public struct TopRow: Sendable, Equatable {
  public let footprint: UInt64
  public let cpuPercent: Double
  public init(footprint: UInt64, cpuPercent: Double) {
    self.footprint = footprint
    self.cpuPercent = cpuPercent
  }
}

/// Parses `top` output columns `PID MEM %CPU`, using only the rows after the last `PID` header line.
public func parseTopOutput(_ text: String) -> [Int32: TopRow] {
  let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
  guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [:] }
  var rows: [Int32: TopRow] = [:]
  for line in lines[(header + 1)...] {
    let f = line.split(whereSeparator: \.isWhitespace)
    guard f.count >= 3, let pid = Int32(f[0]), let bytes = parseTopMem(String(f[1])), let cpu = Double(f[2]) else { continue }
    rows[pid] = TopRow(footprint: bytes, cpuPercent: cpu)
  }
  return rows
}

private func parseTopMem(_ s: String) -> UInt64? {
  var s = Substring(s)
  if s.last == "+" || s.last == "-" { s = s.dropLast() }
  guard let unit = s.last else { return nil }
  let shift: Int
  switch unit {
  case "B": shift = 0
  case "K": shift = 10
  case "M": shift = 20
  case "G": shift = 30
  case "T": shift = 40
  default: return nil
  }
  guard let n = Double(s.dropLast()), n >= 0, n.isFinite else { return nil }
  return UInt64(n * Double(UInt64(1) << UInt64(shift)))
}

/// PIDs of running jobs from `launchctl list` (header skipped, `-` PIDs ignored).
public func parseLaunchctlList(_ text: String) -> Set<Int32> {
  Set(text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
    line.split(separator: "\t", omittingEmptySubsequences: false).first.flatMap { Int32($0) }
  })
}
