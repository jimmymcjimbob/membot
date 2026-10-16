import SwiftUI
import MemBotCore

struct ProcessRow: Identifiable {
  let id: Int32
  let key: ProcessKey?
  let name: String
  /// Grey text after the name: `· count · folder` on a group, the pid on a child.
  let suffix: String
  let footprint: UInt64
  let cpuPercent: Double
  let ports: String
  let status: ProcessStatus?
  let children: [ProcessRow]?
}

func tilde(_ path: String) -> String {
  let home = NSHomeDirectory()
  return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

func listeningPorts(_ s: ProcessSample?) -> String {
  Set((s?.sockets ?? []).filter(\.isListening).map(\.localPort)).sorted().map(String.init).joined(separator: ", ")
}

/// `cpu` holds each process's own CPU %; node totals would include children that a filter has pruned.
func makeRows(_ groups: [RootGroup], statuses: [Int32: ProcessStatus], cpu: [Int32: Double] = [:]) -> [ProcessRow] {
  func child(_ n: ProcessNode) -> ProcessRow {
    ProcessRow(id: n.pid, key: n.sample?.key, name: n.sample?.name ?? "pid \(n.pid)", suffix: String(n.pid),
               footprint: n.sample?.footprint ?? 0, cpuPercent: cpu[n.pid] ?? 0, ports: listeningPorts(n.sample),
               status: statuses[n.pid], children: n.children.isEmpty ? nil : n.children.map(child))
  }
  return groups.map { g in
    var suffix = "· \(g.node.descendantCount)"
    if let cwd = g.cwd { suffix += " · \(tilde(cwd))" }
    return ProcessRow(id: g.node.pid, key: g.node.sample?.key, name: g.name,
                      suffix: g.node.descendantCount == 0 && g.cwd == nil ? "" : suffix,
                      footprint: g.node.totalFootprint, cpuPercent: g.node.totalCPUPercent,
                      ports: listeningPorts(g.node.sample), status: statuses[g.node.pid],
                      children: g.node.children.isEmpty ? nil : g.node.children.map(child))
  }
}

private func sorted(_ rows: [ProcessRow], _ order: [KeyPathComparator<ProcessRow>]) -> [ProcessRow] {
  rows.sorted(using: order).map { r in
    ProcessRow(id: r.id, key: r.key, name: r.name, suffix: r.suffix, footprint: r.footprint, cpuPercent: r.cpuPercent,
               ports: r.ports, status: r.status, children: r.children.map { sorted($0, order) })
  }
}

struct ProcessTable: View {
  let rows: [ProcessRow]
  let now: Date
  @Binding var selection: Int32?
  @State private var order = [KeyPathComparator(\ProcessRow.footprint, order: .reverse)]

  var body: some View {
    Table(sorted(rows, order), children: \.children, selection: $selection, sortOrder: $order) {
      TableColumn("Process", value: \.name) { r in
        HStack(spacing: 4) {
          Text(r.name).lineLimit(1)
          if !r.suffix.isEmpty { Text(r.suffix).foregroundStyle(.secondary).lineLimit(1) }
        }
      }
      TableColumn("Memory", value: \.footprint) { r in Text(formatBytes(r.footprint)).monospacedDigit() }
        .width(min: 70, ideal: 80)
      TableColumn("CPU", value: \.cpuPercent) { r in Text("\(Int(r.cpuPercent.rounded()))%").monospacedDigit() }
        .width(min: 45, ideal: 55)
      TableColumn("Ports") { r in Text(r.ports).lineLimit(1) }
        .width(min: 50, ideal: 80)
      TableColumn("Status") { r in StatusCell(status: r.status, now: now) }
        .width(min: 90, ideal: 110)
    }
  }
}

struct StatusCell: View {
  let status: ProcessStatus?
  let now: Date

  var body: some View {
    if let status {
      HStack(spacing: 6) {
        Circle().fill(color(status)).frame(width: 8, height: 8)
        Text(label(status)).foregroundStyle(.secondary)
      }
    }
  }

  private func color(_ s: ProcessStatus) -> Color {
    switch s {
    case .active: Color(red: 0x3f / 255, green: 0xb9 / 255, blue: 0x6b / 255)
    case .idle: .gray
    case .candidate: Color(red: 0xf0 / 255, green: 0xa4 / 255, blue: 0x3a / 255)
    }
  }

  private func label(_ s: ProcessStatus) -> String {
    switch s {
    case .active: "active"
    case .idle(let since): "idle \(formatDuration(now.timeIntervalSince(since)))"
    case .candidate: "candidate"
    }
  }
}
