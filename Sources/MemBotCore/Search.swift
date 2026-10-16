import Foundation

public enum FilterMode: Sendable { case all, candidates, aiTools }

public func filterForest(_ groups: [RootGroup], query: String, mode: FilterMode,
                         candidatePIDs: Set<Int32>, aiToolNames: [String]) -> [RootGroup] {
  var gs = groups
  switch mode {
  case .all: break
  case .candidates:
    gs = gs.compactMap { g in prune(g.node) { candidatePIDs.contains($0.pid) }.map { with(g, $0) } }
  case .aiTools:
    gs = gs.filter { isAITool($0, names: aiToolNames) }
  }
  let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  guard !q.isEmpty else { return gs }
  return gs.compactMap { g in
    if g.name.lowercased().contains(q) || (g.cwd?.lowercased().contains(q) ?? false) { return g }
    return prune(g.node) { matches($0, q) }.map { with(g, $0) }
  }
}

private func with(_ g: RootGroup, _ node: ProcessNode) -> RootGroup {
  RootGroup(kind: g.kind, name: g.name, cwd: g.cwd, node: node, lastKnownRoot: g.lastKnownRoot)
}

private func matches(_ n: ProcessNode, _ q: String) -> Bool {
  guard let s = n.sample else { return false }
  return s.name.lowercased().contains(q) || String(s.pid) == q
    || (s.sockets ?? []).contains { String($0.localPort) == q }
    || (s.cwd?.lowercased().contains(q) ?? false)
}

/// A matching node keeps its whole subtree; otherwise only matching branches survive. Totals are left untouched.
private func prune(_ n: ProcessNode, _ hit: (ProcessNode) -> Bool) -> ProcessNode? {
  if hit(n) { return n }
  let kids = n.children.compactMap { prune($0, hit) }
  guard !kids.isEmpty else { return nil }
  var copy = n
  copy.children = kids
  return copy
}
