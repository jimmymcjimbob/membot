@testable import MemBotCore

func proc(_ pid: Int32, ppid: Int32, name: String, path: String? = nil, uid: UInt32 = 501,
          footprint: UInt64? = 0, cpuTimeNs: UInt64? = 0, diskBytes: UInt64? = 0,
          start: UInt64 = 1, args: [String]? = nil, cwd: String? = nil,
          sockets: [SocketInfo]? = []) -> ProcessSample {
  ProcessSample(key: ProcessKey(pid: pid, startTime: start), ppid: ppid, uid: uid, name: name,
                path: path ?? "/usr/local/bin/\(name)", footprint: footprint, cpuTimeNs: cpuTimeNs,
                diskBytes: diskBytes, sockets: sockets, arguments: args, cwd: cwd)
}
