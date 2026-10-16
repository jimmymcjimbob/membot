import Darwin
import MemBotCore

public enum SignalResult: Equatable, Sendable {
  case sent, processChanged, notPermitted, noSuchProcess, failed(Int32)
}

/// Sends `signal` only if `key.pid` is still the process that `key` was sampled from.
public func sendSignal(_ signal: Int32, to key: ProcessKey) -> SignalResult {
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, key.pid]
  var kp = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return .noSuchProcess }
  guard SystemReader.startTime(kp) == key.startTime else { return .processChanged }
  if kill(key.pid, signal) == 0 { return .sent }
  switch errno {
  case EPERM: return .notPermitted
  case ESRCH: return .noSuchProcess
  case let e: return .failed(e)
  }
}
