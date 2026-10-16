import Foundation
import MemBotCore

public enum Commands {
  public static func top() async -> [Int32: TopRow]? {
    await run("/usr/bin/top", ["-l", "2", "-s", "1", "-stats", "pid,mem,cpu"]).map(parseTopOutput)
  }

  public static func launchdJobs() async -> Set<Int32>? {
    await run("/bin/launchctl", ["list"]).map(parseLaunchctlList)
  }

  /// stdout, or `nil` on launch error, non-zero exit, or the 10 s time limit.
  static func run(_ path: String, _ args: [String]) async -> String? {
    await withCheckedContinuation { cont in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return cont.resume(returning: nil) }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        // Read before waiting so a full pipe cannot deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let ok = process.terminationReason == .exit && process.terminationStatus == 0
        cont.resume(returning: ok ? String(decoding: data, as: UTF8.self) : nil)
      }
    }
  }
}
