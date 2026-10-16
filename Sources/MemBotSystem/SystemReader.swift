import Darwin
import MemBotCore

public struct SystemRaw: Sendable {
  public let memUsed: UInt64
  public let memTotal: UInt64
  public let swapUsed: UInt64
  public let ticks: CPUTicks
}

/// The only code that reads the OS. Every call tolerates processes exiting mid-read.
public enum SystemReader {
  private static let host = mach_host_self()
  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info.denom == 0 ? mach_timebase_info_data_t(numer: 1, denom: 1) : info
  }()
  /// Same value as `vm_kernel_page_size`, which Swift 6 rejects as shared mutable state.
  private static let pageSize: UInt64 = {
    var size: vm_size_t = 0
    return host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : UInt64(getpagesize())
  }()

  private static func string(_ bytes: UnsafeRawBufferPointer) -> String {
    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }

  public static func listProcesses() -> [ProcessSample] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var procs: [kinfo_proc] = []
    for _ in 0..<5 {
      var size = 0
      guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
      let count = size / MemoryLayout<kinfo_proc>.stride + size / MemoryLayout<kinfo_proc>.stride / 10 + 1
      var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
      size = count * MemoryLayout<kinfo_proc>.stride
      if sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 {
        procs = Array(buffer.prefix(size / MemoryLayout<kinfo_proc>.stride))
        break
      }
      if errno != ENOMEM { return [] }
    }
    return procs.map(sample)
  }

  private static func sample(_ kp: kinfo_proc) -> ProcessSample {
    let pid = kp.kp_proc.p_pid
    let path = pidPath(pid)
    let comm = withUnsafeBytes(of: kp.kp_proc.p_comm, string)
    let name = path.isEmpty ? comm : String(path.split(separator: "/").last ?? Substring(comm))
    var footprint: UInt64?, cpu: UInt64?, disk: UInt64?
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    if ok == 0 {
      footprint = info.ri_phys_footprint
      cpu = (info.ri_user_time &+ info.ri_system_time) &* UInt64(timebase.numer) / UInt64(timebase.denom)
      disk = info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten
    }
    return ProcessSample(
      key: ProcessKey(pid: pid, startTime: startTime(kp)), ppid: kp.kp_eproc.e_ppid,
      uid: kp.kp_eproc.e_ucred.cr_uid, name: name, path: path,
      footprint: footprint, cpuTimeNs: cpu, diskBytes: disk)
  }

  /// µs since 1970, the same value `sendSignal` compares against.
  static func startTime(_ kp: kinfo_proc) -> UInt64 {
    let t = kp.kp_proc.p_un.__p_starttime
    return UInt64(truncatingIfNeeded: t.tv_sec) &* 1_000_000 &+ UInt64(truncatingIfNeeded: t.tv_usec)
  }

  private static func pidPath(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
    return buf.withUnsafeBytes(string)
  }

  public static func arguments(_ pid: Int32) -> [String]? {
    var argmax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: Int(argmax))
    size = buf.count
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    return parseProcArgs(Array(buf.prefix(size)))
  }

  public static func cwd(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path, string)
    return path.isEmpty ? nil : path
  }

  /// `nil` when the fd list cannot be read (for example, another user's process).
  public static func sockets(_ pid: Int32) -> [SocketInfo]? {
    errno = 0
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    if bytes < 0 || (bytes == 0 && errno != 0) { return nil }
    let stride = MemoryLayout<proc_fdinfo>.stride
    // Headroom for fds opened between the two calls.
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    if got < 0 || (got == 0 && bytes > 0) { return nil }
    return fds.prefix(Int(got) / stride).compactMap { fd in
      guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
      var si = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size else { return nil }
      switch si.psi.soi_kind {
      case Int32(SOCKINFO_TCP):
        let tcp = si.psi.soi_proto.pri_tcp
        return socketInfo(.tcp, tcp.tcpsi_ini, listening: tcp.tcpsi_state == TSI_S_LISTEN)
      case Int32(SOCKINFO_IN):
        let ini = si.psi.soi_proto.pri_in
        return socketInfo(.udp, ini, listening: ini.insi_fport == 0)
      default:
        return nil
      }
    }
  }

  private static func socketInfo(_ proto: SocketProto, _ ini: in_sockinfo, listening: Bool) -> SocketInfo {
    let v4 = ini.insi_vflag & UInt8(INI_IPV4) != 0
    let remotePort = UInt16(truncatingIfNeeded: ini.insi_fport).bigEndian
    return SocketInfo(
      proto: proto,
      localAddress: v4 ? address(ini.insi_laddr.ina_46.i46a_addr4) : address(ini.insi_laddr.ina_6),
      localPort: UInt16(truncatingIfNeeded: ini.insi_lport).bigEndian,
      remoteAddress: remotePort == 0 ? nil : (v4 ? address(ini.insi_faddr.ina_46.i46a_addr4) : address(ini.insi_faddr.ina_6)),
      remotePort: remotePort == 0 ? nil : remotePort,
      isListening: listening)
  }

  private static func address(_ addr: in_addr) -> String { address(AF_INET, addr) }
  private static func address(_ addr: in6_addr) -> String { address(AF_INET6, addr) }
  private static func address<T>(_ family: Int32, _ addr: T) -> String {
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let ok = withUnsafeBytes(of: addr) { inet_ntop(family, $0.baseAddress, &buf, socklen_t(buf.count)) != nil }
    return ok ? buf.withUnsafeBytes(string) : ""
  }

  public static func system() -> SystemRaw {
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let vmOK = withUnsafeMutablePointer(to: &vm) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
    }
    var memUsed: UInt64 = 0
    if vmOK == KERN_SUCCESS {
      let pages = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count) &+ UInt64(vm.wire_count) &+ UInt64(vm.compressor_page_count)
      memUsed = pages &* pageSize
    }

    var cpu = host_cpu_load_info()
    count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let cpuOK = withUnsafeMutablePointer(to: &cpu) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
    }
    let t = cpuOK == KERN_SUCCESS ? cpu.cpu_ticks : (0, 0, 0, 0)
    let ticks = CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))

    var memTotal: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    if sysctlbyname("hw.memsize", &memTotal, &size, nil, 0) != 0 { memTotal = 0 }
    var swap = xsw_usage()
    size = MemoryLayout<xsw_usage>.size
    let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
    return SystemRaw(memUsed: memUsed, memTotal: memTotal, swapUsed: swapUsed, ticks: ticks)
  }
}
