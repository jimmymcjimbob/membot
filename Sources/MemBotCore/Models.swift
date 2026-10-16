import Foundation

public struct ProcessKey: Hashable, Sendable {
  public let pid: Int32
  /// Microseconds since 1970.
  public let startTime: UInt64
  public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

public enum SocketProto: String, Sendable { case tcp, udp }

public struct SocketInfo: Hashable, Sendable {
  public let proto: SocketProto
  public let localAddress: String
  public let localPort: UInt16
  public let remoteAddress: String?
  public let remotePort: UInt16?
  public let isListening: Bool
  public init(proto: SocketProto, localAddress: String, localPort: UInt16, remoteAddress: String?, remotePort: UInt16?, isListening: Bool) {
    self.proto = proto; self.localAddress = localAddress; self.localPort = localPort
    self.remoteAddress = remoteAddress; self.remotePort = remotePort; self.isListening = isListening
  }
}

/// `nil` on an optional field means "not available".
public struct ProcessSample: Sendable, Equatable {
  public let key: ProcessKey
  public let ppid: Int32
  public let uid: UInt32
  public let name: String
  public let path: String
  public let footprint: UInt64?
  public let cpuTimeNs: UInt64?
  /// Set only from `top`.
  public let cpuPercent: Double?
  /// Cumulative bytes read + written.
  public let diskBytes: UInt64?
  public let sockets: [SocketInfo]?
  public let arguments: [String]?
  public let cwd: String?
  public var pid: Int32 { key.pid }
  public init(key: ProcessKey, ppid: Int32, uid: UInt32, name: String, path: String,
              footprint: UInt64? = nil, cpuTimeNs: UInt64? = nil, cpuPercent: Double? = nil,
              diskBytes: UInt64? = nil, sockets: [SocketInfo]? = nil, arguments: [String]? = nil, cwd: String? = nil) {
    self.key = key; self.ppid = ppid; self.uid = uid; self.name = name; self.path = path
    self.footprint = footprint; self.cpuTimeNs = cpuTimeNs; self.cpuPercent = cpuPercent
    self.diskBytes = diskBytes; self.sockets = sockets; self.arguments = arguments; self.cwd = cwd
  }
}

public struct SystemSample: Sendable, Equatable {
  public let memUsed: UInt64
  public let memTotal: UInt64
  public let swapUsed: UInt64
  public let cpuPercent: Double
  public init(memUsed: UInt64, memTotal: UInt64, swapUsed: UInt64, cpuPercent: Double) {
    self.memUsed = memUsed; self.memTotal = memTotal; self.swapUsed = swapUsed; self.cpuPercent = cpuPercent
  }
}

public struct Snapshot: Sendable {
  public let time: Date
  public let system: SystemSample
  public let processes: [Int32: ProcessSample]
  public init(time: Date, system: SystemSample, processes: [Int32: ProcessSample]) {
    self.time = time; self.system = system; self.processes = processes
  }
}

public struct CPUTicks: Sendable, Equatable {
  public let user: UInt64
  public let system: UInt64
  public let idle: UInt64
  public let nice: UInt64
  public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
    self.user = user; self.system = system; self.idle = idle; self.nice = nice
  }
}
