import Darwin
import Foundation
import Testing
@testable import MemBotCore
@testable import MemBotSystem

@Suite struct SystemReaderTests {
  @Test func listsSelfWithData() {
    let all = SystemReader.listProcesses()
    let me = all.first { $0.pid == getpid() }
    #expect(me?.uid == getuid())
    #expect((me?.footprint ?? 0) > 0)
    #expect(me?.cpuTimeNs != nil)
    let launchd = all.first { $0.pid == 1 }
    #expect(launchd?.path == "/sbin/launchd")
    #expect(launchd != nil && launchd?.footprint == nil)
    #expect(SystemReader.sockets(1) == nil)
  }

  @Test func readsOwnDetails() {
    #expect(SystemReader.arguments(getpid())?.isEmpty == false)
    #expect(SystemReader.cwd(getpid()) == FileManager.default.currentDirectoryPath)
  }

  @Test func readsListeningSocket() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)
    let named = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    try #require(named == 0)
    let port = UInt16(bigEndian: addr.sin_port)
    let socks = try #require(SystemReader.sockets(getpid()))
    let mine = socks.first { $0.localPort == port }
    #expect(mine?.isListening == true)
    #expect(mine?.proto == .tcp)
    #expect(mine?.localAddress == "127.0.0.1")
  }

  @Test func systemTotals() {
    let s = SystemReader.system()
    #expect(s.memTotal > 0)
    #expect(s.memUsed > 0)
    #expect(s.memUsed < s.memTotal)
  }

  @Test func signalChecksStartTime() throws {
    let all = SystemReader.listProcesses()
    #expect(sendSignal(0, to: ProcessKey(pid: getpid(), startTime: 1)) == .processChanged)
    let me = try #require(all.first { $0.pid == getpid() })
    #expect(sendSignal(0, to: me.key) == .sent)
    let launchd = try #require(all.first { $0.pid == 1 })
    #expect(sendSignal(0, to: launchd.key) == .notPermitted)
    let kernel = try #require(all.first { $0.pid == 0 })
    #expect(sendSignal(0, to: kernel.key) == .notPermitted)
    #expect(sendSignal(0, to: ProcessKey(pid: -getpid(), startTime: me.key.startTime)) == .notPermitted)
  }

  @Test func commandsRun() async {
    let jobs = await Commands.launchdJobs()
    #expect(jobs?.isEmpty == false)
    let top = await Commands.top()
    #expect((top?[1]?.footprint ?? 0) > 0)
  }
}
