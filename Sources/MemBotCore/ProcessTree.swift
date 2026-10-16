import Foundation

public enum RootKind: Equatable, Sendable {
  case app(bundlePath: String), command, orphan, backgroundServices
}

public struct ProcessNode: Identifiable, Sendable {
  public let pid: Int32
  public let sample: ProcessSample?
  public var children: [ProcessNode]
  public var totalFootprint: UInt64
  public var totalCPUPercent: Double
  public var descendantCount: Int
  public var id: Int32 { pid }
  public init(pid: Int32, sample: ProcessSample?, children: [ProcessNode], totalFootprint: UInt64,
              totalCPUPercent: Double, descendantCount: Int) {
    self.pid = pid; self.sample = sample; self.children = children; self.totalFootprint = totalFootprint
    self.totalCPUPercent = totalCPUPercent; self.descendantCount = descendantCount
  }
}

public struct RootGroup: Identifiable, Sendable {
  public let kind: RootKind
  public let name: String
  public let cwd: String?
  public var node: ProcessNode
  public let lastKnownRoot: String?
  public var id: Int32 { node.pid }
  public init(kind: RootKind, name: String, cwd: String?, node: ProcessNode, lastKnownRoot: String?) {
    self.kind = kind; self.name = name; self.cwd = cwd; self.node = node; self.lastKnownRoot = lastKnownRoot
  }
}

public struct TreeInput: Sendable {
  public let processes: [Int32: ProcessSample]
  public let cpuPercent: [Int32: Double]
  public let ownerUID: UInt32
  public let terminalHosts: Set<String>
  /// `nil` means `launchctl` failed.
  public let launchdJobPIDs: Set<Int32>?
  public init(processes: [Int32: ProcessSample], cpuPercent: [Int32: Double], ownerUID: UInt32,
              terminalHosts: Set<String>, launchdJobPIDs: Set<Int32>?) {
    self.processes = processes; self.cpuPercent = cpuPercent; self.ownerUID = ownerUID
    self.terminalHosts = terminalHosts; self.launchdJobPIDs = launchdJobPIDs
  }
}

public struct RootMemory: Sendable {
  private var entries: [ProcessKey: (ppid: Int32, root: String)] = [:]
  public init() {}

  public mutating func record(_ groups: [RootGroup]) {
    var next: [ProcessKey: (ppid: Int32, root: String)] = [:]
    func visit(_ n: ProcessNode, _ root: String) {
      if let s = n.sample {
        if s.ppid != 0, s.ppid != 1 { next[s.key] = (s.ppid, root) }
        else if let old = entries[s.key] { next[s.key] = old } // reparented: keep the old root
      }
      n.children.forEach { visit($0, root) }
    }
    for g in groups { visit(g.node, g.name) }
    entries = next
  }

  public func wasReparented(_ s: ProcessSample) -> Bool { entries[s.key] != nil && s.ppid == 1 }
  public func lastRoot(_ key: ProcessKey) -> String? { entries[key]?.root }
}

/// The prefix up to and including the first path component ending in `.app`.
public func bundlePath(_ path: String) -> String? {
  let parts = path.split(separator: "/", omittingEmptySubsequences: false)
  guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
  return parts[...i].joined(separator: "/")
}

public func isAITool(_ group: RootGroup, names: [String]) -> Bool {
  guard group.kind != .backgroundServices else { return false }
  let hay = [group.name, group.node.sample?.path ?? ""].map { $0.lowercased() }
  return names.contains { n in !n.isEmpty && hay.contains { $0.contains(n.lowercased()) } }
}

private func bundleName(_ bundle: String) -> String {
  let last = bundle.split(separator: "/").last.map(String.init) ?? bundle
  return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
}

private func hostName(_ p: ProcessSample) -> String { bundlePath(p.path).map(bundleName) ?? p.name }

private func isShell(_ p: ProcessSample) -> Bool {
  ["zsh", "bash", "sh", "fish"].contains(p.name.hasPrefix("-") ? String(p.name.dropFirst()) : p.name)
}

private enum Place { case background, root(RootKind), child(Int32) }

public func buildForest(_ input: TreeInput, memory: RootMemory) -> [RootGroup] {
  let procs = input.processes

  // Mark processes on a ppid cycle; they count as having no parent.
  var inCycle = Set<Int32>()
  var done = Set<Int32>()
  for start in procs.keys where !done.contains(start) {
    var path: [Int32] = [], onPath = Set<Int32>(), cur: Int32? = start
    while let c = cur, !done.contains(c), let p = procs[c] {
      if onPath.contains(c) { inCycle.formUnion(path[path.firstIndex(of: c)!...]); break }
      onPath.insert(c); path.append(c); cur = p.ppid
    }
    done.formUnion(path)
  }

  func parent(_ p: ProcessSample) -> ProcessSample? {
    guard p.ppid != 0, p.ppid != p.pid, !inCycle.contains(p.pid) else { return nil }
    return procs[p.ppid]
  }
  func terminalOf(_ sh: ProcessSample) -> ProcessSample? {
    var t = parent(sh)
    while let x = t, x.name == "login" { t = parent(x) }
    return t
  }
  let underSystem = ["/System/", "/usr/libexec/", "/usr/sbin/"]

  func place(_ p: ProcessSample) -> Place {
    if p.pid == 0 || p.pid == 1 { return .background }
    let par = parent(p)
    if let b = bundlePath(p.path), par == nil || par!.pid == 1 || bundlePath(par!.path) != b { return .root(.app(bundlePath: b)) }
    if let par, isShell(par), let t = terminalOf(par), input.terminalHosts.contains(hostName(t)) { return .root(.command) }
    guard let par else { return orphanOrBackground(p) }
    return par.pid == 1 ? orphanOrBackground(p) : .child(par.pid)
  }
  func orphanOrBackground(_ p: ProcessSample) -> Place {
    if input.terminalHosts.contains(hostName(p)) { return .background }
    guard p.uid == input.ownerUID, !underSystem.contains(where: p.path.hasPrefix),
          memory.wasReparented(p) || input.launchdJobPIDs?.contains(p.pid) == false else { return .background }
    return .root(.orphan)
  }

  var children: [Int32: [Int32]] = [:]
  var roots: [(ProcessSample, RootKind)] = []
  var background: [Int32] = []
  for (pid, p) in procs {
    switch place(p) {
    case .background: background.append(pid)
    case .root(let k): roots.append((p, k))
    case .child(let par): children[par, default: []].append(pid)
    }
  }

  func node(_ pid: Int32) -> ProcessNode {
    let s = procs[pid]!
    let kids = (children[pid] ?? []).map(node).sorted(by: bigger)
    return ProcessNode(pid: pid, sample: s, children: kids,
                       totalFootprint: (s.footprint ?? 0) + kids.reduce(0) { $0 + $1.totalFootprint },
                       totalCPUPercent: (input.cpuPercent[pid] ?? 0) + kids.reduce(0) { $0 + $1.totalCPUPercent },
                       descendantCount: kids.reduce(0) { $0 + 1 + $1.descendantCount })
  }

  var groups = roots.map { p, kind -> RootGroup in
    let name: String
    switch kind {
    case .app(let b): name = bundleName(b)
    case .command: name = (p.arguments ?? []).joined(separator: " ").contains("ComfyUI") ? "ComfyUI" : p.name
    default: name = p.name
    }
    return RootGroup(kind: kind, name: name, cwd: kind == .command ? p.cwd : nil, node: node(p.pid),
                     lastKnownRoot: kind == .orphan ? memory.lastRoot(p.key) : nil)
  }
  if !background.isEmpty {
    let kids = background.map(node).sorted(by: bigger)
    let bg = ProcessNode(pid: -1, sample: nil, children: kids,
                         totalFootprint: kids.reduce(0) { $0 + $1.totalFootprint },
                         totalCPUPercent: kids.reduce(0) { $0 + $1.totalCPUPercent },
                         descendantCount: kids.reduce(0) { $0 + 1 + $1.descendantCount })
    groups.append(RootGroup(kind: .backgroundServices, name: "Background services", cwd: nil, node: bg, lastKnownRoot: nil))
  }
  return groups.sorted { bigger($0.node, $1.node) }
}

private func bigger(_ a: ProcessNode, _ b: ProcessNode) -> Bool {
  a.totalFootprint != b.totalFootprint ? a.totalFootprint > b.totalFootprint : a.pid < b.pid
}
