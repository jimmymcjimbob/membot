import SwiftUI
import MemBotCore
import MemBotSystem

private let startFormatter: DateFormatter = {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = "HH:mm"
  return f
}()

/// Everything the panel shows for one live process, kept so the last values survive when it ends.
private struct Seen {
  let sample: ProcessSample
  let reasonsTitle: String
  let reasons: [String]
  let root: String
  let parent: String
  let children: String

  init(_ s: ProcessSample, _ state: MonitorState) {
    sample = s
    if let c = state.evaluation.candidates.first(where: { $0.key == s.key }) {
      reasonsTitle = "Why it is a candidate"; reasons = c.reasons
    } else {
      reasonsTitle = "Status"
      switch state.evaluation.statuses[s.pid] {
      case .active: reasons = ["Active"]
      case .idle(let since): reasons = ["Idle for \(formatDuration(state.snapshot.time.timeIntervalSince(since)))"]
      case .candidate, nil: reasons = ["not available"]
      }
    }
    let found = Seen.locate(s.pid, state.groups)
    let group = found?.0
    let orphan = group?.kind == .orphan && found?.1.pid == group?.node.pid // only the orphan root lost its parent
    root = group.map { g in tilde([g.name, g.cwd].compactMap { $0 }.joined(separator: " · ")) }
      .map { r in orphan ? (group?.lastKnownRoot.map { "was under \($0)" } ?? r) : r } ?? "not available"
    parent = orphan ? "parent gone" : state.snapshot.processes[s.ppid].map { "\($0.name) \($0.pid)" } ?? "none"
    let kids = found?.1.children ?? []
    children = kids.isEmpty ? "none" : "\(kids.count): " + kids.prefix(5).map { $0.sample?.name ?? "pid \($0.pid)" }.joined(separator: ", ")
  }

  static func locate(_ pid: Int32, _ groups: [RootGroup]) -> (RootGroup, ProcessNode)? {
    func find(_ n: ProcessNode) -> ProcessNode? {
      n.pid == pid ? n : n.children.lazy.compactMap(find).first
    }
    for g in groups { if let n = find(g.node) { return (g, n) } }
    return nil
  }
}

struct DetailPanel: View {
  @Environment(AppModel.self) private var model
  let pid: Int32
  let state: MonitorState
  @State private var seen: Seen?
  @State private var points: [HistoryPoint] = []

  private struct TaskID: Equatable { let time: Date; let pid: Int32 }

  /// The live process, unless the pid now belongs to a process with a different start time.
  private var live: ProcessSample? {
    let s = state.snapshot.processes[pid]
    guard let seen else { return s }
    return s?.key == seen.sample.key ? s : nil
  }
  private var shown: Seen? { live.map { Seen($0, state) } ?? seen }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if pid == -1 { background }
        else if let s = shown { process(s, ended: live == nil) }
        else { Text("process ended").foregroundStyle(.secondary) }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
    }
    .font(.system(size: 12))
    .task(id: TaskID(time: state.snapshot.time, pid: pid)) {
      guard let live else { return }
      seen = Seen(live, state)
      let h = await model.history(live.key)
      if !Task.isCancelled { points = h }
    }
  }

  @ViewBuilder private var background: some View {
    if let g = state.groups.first(where: { $0.kind == .backgroundServices }) {
      Text(g.name).font(.title3.bold())
      Text("\(g.node.descendantCount) processes · \(formatBytes(g.node.totalFootprint)) · CPU \(Int(g.node.totalCPUPercent.rounded()))%")
        .foregroundStyle(.secondary)
    } else {
      Text("process ended").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func process(_ v: Seen, ended: Bool) -> some View {
    let s = v.sample
    let start = Date(timeIntervalSince1970: Double(s.key.startTime) / 1_000_000)
    VStack(alignment: .leading, spacing: 2) {
      Text(s.name).font(.title3.bold())
      Text("pid \(s.pid) · \(owner(s.uid)) · started \(startFormatter.string(from: start)) (\(formatDuration(state.snapshot.time.timeIntervalSince(start))) ago)")
        .foregroundStyle(.secondary)
      if ended { Text("process ended").foregroundStyle(.red) }
    }
    section("Memory and CPU, last 10 min") { graph(v) }
    section("Command") {
      kv("Command", s.arguments.map { $0.joined(separator: " ") } ?? "not available", mono: true)
      kv("Folder", s.cwd.map(tilde) ?? "not available", mono: true)
    }
    section("Family") {
      kv("Root", v.root); kv("Parent", v.parent); kv("Children", v.children)
    }
    section("Ports and connections") {
      if let socks = s.sockets {
        let listens = socks.filter(\.isListening)
        let conns = socks.filter { !$0.isListening }
        kv("Listens", listens.isEmpty ? "none" : listens.map(addr).joined(separator: "\n"), mono: true)
        kv("Connections", conns.isEmpty ? "none" : conns.map { c in
          "\(addr(c)) → \(c.remoteAddress ?? "?"):\(c.remotePort.map(String.init) ?? "?")" }.joined(separator: "\n"), mono: true)
      } else {
        kv("Listens", "not available"); kv("Connections", "not available")
      }
    }
    section(v.reasonsTitle) {
      ForEach(v.reasons, id: \.self) { Text("• \($0)") }
    }
    if !ended {
      SignalButtons(key: s.key, name: s.name, canSignal: model.canSignal(s), compact: false)
    }
  }

  private func graph(_ v: Seen) -> some View {
    UsageGraph(points: points, end: state.snapshot.time, footprint: v.sample.footprint)
  }

  private func addr(_ s: SocketInfo) -> String {
    "\(s.localAddress):\(s.localPort) (\(s.proto.rawValue.uppercased()))"
  }

  private func owner(_ uid: UInt32) -> String {
    getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
  }

  private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary)
      body()
    }
  }

  private func kv(_ k: String, _ v: String, mono: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
      Text(v).font(mono ? .system(size: 11, design: .monospaced) : nil)
    }
  }
}
