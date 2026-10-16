import Testing
@testable import MemBotCore

@Test func procArgs() {
  var b: [UInt8] = [2, 0, 0, 0]
  b += Array("/usr/bin/python3".utf8) + [0, 0, 0]
  b += Array("python3".utf8) + [0] + Array("main.py".utf8) + [0]
  b += Array("PATH=/bin".utf8) + [0]
  #expect(parseProcArgs(b) == ["python3", "main.py"])
  #expect(parseProcArgs([1, 0]) == nil)
}

@Test func procArgsMalformed() {
  #expect(parseProcArgs([]) == nil)
  #expect(parseProcArgs([2, 0, 0, 0] + Array("/bin/x".utf8)) == nil)  // no NUL after path
  #expect(parseProcArgs([2, 0, 0, 0] + Array("/bin/x".utf8) + [0, 0] + Array("x".utf8) + [0]) == nil)  // argc 2, one string
  #expect(parseProcArgs([255, 255, 255, 255, 0]) == nil)  // negative argc
}

@Test func top() {
  let text = """
  Processes: 900 total
  PID    MEM    %CPU
  611    1200M  0.0
  Processes: 901 total
  Disks: 417065732/11T read, 390890562/12T written.

  PID    MEM    %CPU
  611    1223M- 47.7
  0      35M+   15.7
  2407   391K   11.9
  58493  1.5G   0.0
  """
  let rows = parseTopOutput(text)
  #expect(rows.count == 4)
  #expect(rows[611] == TopRow(footprint: 1223 << 20, cpuPercent: 47.7))
  #expect(rows[0]?.footprint == 35 << 20)
  #expect(rows[2407]?.footprint == 391 << 10)
  #expect(rows[58493]?.footprint == UInt64(1.5 * Double(1 << 30)))
}

@Test func topMalformed() {
  #expect(parseTopOutput("").isEmpty)
  #expect(parseTopOutput("PID MEM %CPU\nabc 1M 0.0\n5 xyz 1.0\n6 2M\n7 3M 1.0").keys.sorted() == [7])
}

@Test func launchctl() {
  let text = "PID\tStatus\tLabel\n7781\t-9\tcom.apple.trustd.agent\n-\t0\tcom.apple.MailServiceAgent\n512\t0\thomebrew.mxcl.ollama\n"
  #expect(parseLaunchctlList(text) == [7781, 512])
}
