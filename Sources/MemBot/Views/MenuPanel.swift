import SwiftUI
import AppKit
import MemBotCore
import MemBotSystem

struct MenuPanel: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  @State private var expanded = Set<Int32>()
  /// Candidate order from when the panel opened, so a one-click Term never hits a row that moved.
  @State private var order: [ProcessKey] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let state = model.state {
        content(state)
      } else {
        Text("Sampling…").foregroundStyle(.secondary)
      }
      Divider().padding(.top, 4)
      HStack {
        Button("Open MemBot window…") { openMain() }
        Spacer()
        SettingsLink { Text("Settings…") }
        Button("Quit MemBot") { NSApp.terminate(nil) }
      }.buttonStyle(.plain).foregroundStyle(.secondary)
    }
    .font(.system(size: 12))
    .padding(.horizontal, 14).padding(.vertical, 12)
    .frame(width: 340)
    .onAppear {
      model.visibleSurfaces += 1
      order = candidateKeys
    }
    .onChange(of: candidateKeys) { order = stable(model.state?.evaluation.candidates ?? []).map(\.key) }
    .onDisappear { model.visibleSurfaces = max(0, model.visibleSurfaces - 1) }
  }

  private var candidateKeys: [ProcessKey] { model.state?.evaluation.candidates.map(\.key) ?? [] }

  /// Known keys keep their place (ended ones drop out); new keys go at the end.
  private func stable(_ cs: [Candidate]) -> [Candidate] {
    let byKey = Dictionary(cs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    let known = Set(order)
    return order.compactMap { byKey[$0] } + cs.filter { !known.contains($0.key) }
  }

  private func openMain() {
    openWindow(id: "main")
    NSApp.activate()
  }

  private func row(_ left: some View, _ right: String) -> some View {
    HStack { left; Spacer(); Text(right).monospacedDigit() }
  }

  private func header(_ s: String) -> some View {
    Text(s).font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 8)
  }

  @ViewBuilder private func content(_ state: MonitorState) -> some View {
    let sys = state.snapshot.system
    let memPct = sys.memTotal == 0 ? 0 : Double(sys.memUsed) / Double(sys.memTotal) * 100
    let s = model.settings
    row(Text("Memory"), memoryLine(sys))
    UsageBar(percent: memPct, level: usageLevel(memPct, warnAt: s.warnPercent, critAt: s.critPercent))
    row(Text("CPU"), "\(Int(sys.cpuPercent.rounded()))%").padding(.top, 4)
    UsageBar(percent: sys.cpuPercent, level: usageLevel(sys.cpuPercent, warnAt: s.warnPercent, critAt: s.critPercent))

    header("TOP MEMORY (ROOT + CHILDREN)")
    ForEach(state.groups.prefix(6)) { g in
      let open = expanded.contains(g.id)
      Button {
        if open { expanded.remove(g.id) } else { expanded.insert(g.id) }
      } label: {
        row(Text("\(open ? "▾" : "▸") \(g.name) \(Text("· \(g.node.descendantCount)").foregroundStyle(.secondary))"),
            formatBytes(g.node.totalFootprint))
          .contentShape(Rectangle())
      }.buttonStyle(.plain)
      if open {
        ForEach(g.node.children) { c in
          row(Text(c.sample?.name ?? "pid \(c.pid)"), formatBytes(c.totalFootprint))
            .padding(.leading, 16).foregroundStyle(.secondary)
        }
      }
    }

    let ev = state.evaluation
    header("CANDIDATES FOR REMOVAL · \(ev.candidates.count)")
    if let w = ev.warmup {
      Text("watching · \(Int(w.elapsed / 60)) of \(Int(w.needed / 60)) min").foregroundStyle(.secondary)
    }
    ForEach(stable(ev.candidates).prefix(5)) { c in
      VStack(alignment: .leading, spacing: 2) {
        row(Text("\(c.name) (pid \(c.key.pid))"), formatBytes(c.totalFootprint))
        HStack {
          Text(c.shortReason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
          Spacer()
          SignalButtons(key: c.key, name: c.name,
                        canSignal: state.snapshot.processes[c.key.pid].map { $0.key == c.key && model.canSignal($0) } ?? false,
                        compact: true)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
    if ev.candidates.count > 5 {
      Button("+ \(ev.candidates.count - 5) more") { model.filter = .candidates; openMain() }
        .buttonStyle(.plain).foregroundStyle(.secondary)
    }
  }
}
