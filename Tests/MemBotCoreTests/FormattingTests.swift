import Testing
@testable import MemBotCore

@Test func bytes() {
  #expect(formatBytes(51_539_607_552) == "48.0 GB")
  #expect(formatBytes(673_185_792) == "642 MB")
  #expect(formatBytes(12_582_912) == "12 MB")
  #expect(formatBytes(524_288) == "512 KB")
}
@Test func durations() {
  #expect(formatDuration(47 * 60 + 20) == "47 min")
  #expect(formatDuration(7200) == "2 h")
  #expect(formatDuration(7500) == "2 h 5 min")
  #expect(formatDuration(30) == "0 min")
}
@Test func memLine() {
  let gib: UInt64 = 1 << 30
  let s = SystemSample(memUsed: UInt64(38.2 * Double(gib)), memTotal: 48 * gib, swapUsed: UInt64(4.1 * Double(gib)), cpuPercent: 23)
  #expect(memoryLine(s) == "38.2 / 48 GB · 80% · swap 4.1 GB")
  #expect(memoryLine(SystemSample(memUsed: 24 * gib, memTotal: 48 * gib, swapUsed: 0, cpuPercent: 0)) == "24.0 / 48 GB · 50%")
}
@Test func levels() {
  #expect(usageLevel(59.9, warnAt: 60, critAt: 85) == .ok)
  #expect(usageLevel(60, warnAt: 60, critAt: 85) == .warn)
  #expect(usageLevel(85, warnAt: 60, critAt: 85) == .warn)
  #expect(usageLevel(85.1, warnAt: 60, critAt: 85) == .crit)
}
@Test func cpuTicks() {
  let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
  let b = CPUTicks(user: 150, system: 75, idle: 1025, nice: 0)
  #expect(cpuPercent(from: a, to: b) == 30)
  #expect(cpuPercent(from: a, to: a) == 0)
}
