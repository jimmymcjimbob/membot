import Testing
@testable import MemBotCore

private let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
private let braveHelper = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"

private func input(_ ps: [ProcessSample], jobs: Set<Int32>? = [600]) -> TreeInput {
  TreeInput(processes: Dictionary(uniqueKeysWithValues: ps.map { ($0.pid, $0) }), cpuPercent: [:],
            ownerUID: 501, terminalHosts: Set(MemBotSettings().terminalHosts), launchdJobPIDs: jobs)
}

private func pids(_ n: ProcessNode) -> Set<Int32> { Set([n.pid]).union(n.children.flatMap { pids($0) }) }
private func group(_ gs: [RootGroup], _ name: String) -> RootGroup? { gs.first { $0.name == name } }
private let bgName = "Background services"

@Test func appGroupsHelpers() {
  let gs = buildForest(input([
    proc(56021, ppid: 1, name: "Brave Browser", path: brave, footprint: 50),
    proc(68518, ppid: 56021, name: "Brave Browser Helper (Renderer)", path: braveHelper, footprint: 100),
  ], jobs: nil), memory: RootMemory())
  #expect(gs.count == 1)
  #expect(gs[0].kind == .app(bundlePath: "/Applications/Brave Browser.app"))
  #expect(gs[0].name == "Brave Browser")
  #expect(gs[0].node.children.count == 1)
  #expect(gs[0].node.totalFootprint == 150)
}

private let terminalProcs = [
  proc(2407, ppid: 1, name: "ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", footprint: 10),
  proc(6912, ppid: 2407, name: "login", path: "/usr/bin/login", footprint: 1),
  proc(7000, ppid: 6912, name: "-zsh", footprint: 2),
  proc(62480, ppid: 7000, name: "claude", footprint: 100, cwd: "/Users/james/Code/membot"),
  proc(94987, ppid: 62480, name: "node", footprint: 20),
  proc(95000, ppid: 94987, name: "sh", footprint: 3),
  proc(95001, ppid: 95000, name: "git", footprint: 4),
]

@Test func commandFromTerminalShellIsRoot() throws {
  let gs = buildForest(input(terminalProcs), memory: RootMemory())
  let c = try #require(group(gs, "claude"))
  #expect(c.kind == .command)
  #expect(c.cwd == "/Users/james/Code/membot")
  #expect(pids(c.node).isSuperset(of: [94987, 95000, 95001]))
  let g = try #require(group(gs, "Ghostty"))
  #expect(pids(g.node) == [2407, 6912, 7000])
  #expect(g.node.totalFootprint == 13)
}

@Test func multiplexerShellsMakeRoots() throws {
  let gs = buildForest(input([
    proc(63134, ppid: 1, name: "herdr", path: "/opt/homebrew/bin/herdr"),
    proc(63135, ppid: 63134, name: "-zsh"),
    proc(71123, ppid: 63135, name: "codex"),
  ]), memory: RootMemory())
  #expect(try #require(group(gs, "codex")).kind == .command)
  let bg = try #require(group(gs, bgName))
  #expect(bg.kind == .backgroundServices)
  #expect(pids(bg.node).contains(63134))
  #expect(!gs.contains { $0.kind == .orphan })
}

@Test func comfyName() {
  let gs = buildForest(input([
    proc(1, ppid: 0, name: "launchd"),
    proc(10, ppid: 1, name: "ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
    proc(11, ppid: 10, name: "zsh"),
    proc(12, ppid: 11, name: "python", args: ["python", "/Users/james/ComfyUI/main.py"]),
  ]), memory: RootMemory())
  #expect(group(gs, "ComfyUI")?.kind == .command)
}

@Test func orphanRequiresNotLaunchdJob() throws {
  let node = "/Users/james/.nvm/versions/node/v22.22.0/bin/node"
  let gs = buildForest(input([
    proc(30925, ppid: 1, name: "node", path: node),
    proc(600, ppid: 1, name: "node", path: node),
    proc(601, ppid: 1, name: "rootd", uid: 0),
    proc(602, ppid: 1, name: "foo", path: "/usr/libexec/foo"),
  ]), memory: RootMemory())
  let orphans = gs.filter { $0.kind == .orphan }
  #expect(orphans.map(\.node.pid) == [30925])
  #expect(pids(try #require(group(gs, bgName)).node) == [-1, 600, 601, 602])
}

@Test func launchctlFailedIsConservative() throws {
  var memory = RootMemory()
  memory.record(buildForest(input(terminalProcs + [proc(30925, ppid: 62480, name: "node")]), memory: memory))
  let ps = [proc(30925, ppid: 1, name: "node", path: "/Users/james/bin/node")]
  let noMemory = buildForest(input(ps, jobs: nil), memory: RootMemory())
  #expect(noMemory.allSatisfy { $0.kind == .backgroundServices })
  let gs = buildForest(input(ps, jobs: nil), memory: memory)
  let o = try #require(gs.first { $0.kind == .orphan })
  #expect(o.lastKnownRoot == "claude")
}

@Test func pidReuseIsNotReparent() {
  var memory = RootMemory()
  let old = proc(30925, ppid: 62480, name: "node", start: 1)
  memory.record(buildForest(input([proc(62480, ppid: 1, name: "claude", path: "/Applications/Claude.app/x"), old]), memory: memory))
  #expect(memory.lastRoot(old.key) == "Claude")
  #expect(memory.wasReparented(proc(30925, ppid: 1, name: "node", start: 1)))
  #expect(!memory.wasReparented(proc(30925, ppid: 1, name: "node", start: 2)))
}

@Test func missingParentActsAsLaunchd() {
  let gs = buildForest(input([proc(500, ppid: 499, name: "x", path: "/Users/james/bin/x")]), memory: RootMemory())
  #expect(gs.first?.kind == .orphan)
}

@Test func cycleDoesNotHang() {
  let gs = buildForest(input([proc(10, ppid: 11, name: "a"), proc(11, ppid: 10, name: "b")]), memory: RootMemory())
  #expect(gs.count == 2)
}

@Test func pid0And1InBackground() throws {
  let gs = buildForest(input([proc(0, ppid: 0, name: "kernel_task"), proc(1, ppid: 0, name: "launchd")]), memory: RootMemory())
  let bg = try #require(gs.first)
  #expect(bg.node.pid == -1 && bg.node.sample == nil && bg.name == bgName)
  #expect(Set(bg.node.children.map(\.pid)) == [0, 1])
}

@Test func sortedByFootprint() {
  let gs = buildForest(input([
    proc(1, ppid: 0, name: "launchd", footprint: 5),
    proc(2, ppid: 1, name: "a", path: "/Applications/A.app/a", footprint: 10),
    proc(3, ppid: 1, name: "b", path: "/Applications/B.app/b", footprint: 30),
  ]), memory: RootMemory())
  #expect(gs.map(\.name) == ["B", "A", bgName])
}

@Test func aiTool() throws {
  let gs = buildForest(input(terminalProcs + [
    proc(80, ppid: 1, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"),
    proc(81, ppid: 1, name: "Brave Browser", path: brave),
    proc(1, ppid: 0, name: "launchd"),
  ]), memory: RootMemory())
  let names = MemBotSettings().aiToolNames
  #expect(isAITool(try #require(group(gs, "claude")), names: names))
  #expect(isAITool(try #require(group(gs, "Claude")), names: names))
  #expect(!isAITool(try #require(group(gs, "Brave Browser")), names: names))
  #expect(!isAITool(try #require(group(gs, bgName)), names: names))
}

@Test func orphanSurvivesSecondTick() throws {
  var memory = RootMemory()
  memory.record(buildForest(input(terminalProcs + [proc(30925, ppid: 62480, name: "node")]), memory: memory))
  let orphaned = input([proc(30925, ppid: 1, name: "node", path: "/Users/james/bin/node")], jobs: nil)
  let first = buildForest(orphaned, memory: memory)
  memory.record(first)
  let second = try #require(buildForest(orphaned, memory: memory).first)
  #expect(second.kind == .orphan)
  #expect(second.lastKnownRoot == "claude")
}

private func commandRoot(_ p: ProcessSample) -> [RootGroup] {
  buildForest(input([
    proc(10, ppid: 1, name: "ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
    proc(11, ppid: 10, name: "zsh"),
    p,
  ]), memory: RootMemory())
}

@Test func commandRootNamedFromArgv0() throws {
  let gs = commandRoot(proc(12, ppid: 11, name: "2.1.301",
                            path: "/Users/james/.local/share/claude/versions/2.1.301", args: ["claude"]))
  let c = try #require(gs.first { $0.node.pid == 12 })
  #expect(c.name == "claude")
  #expect(isAITool(c, names: MemBotSettings().aiToolNames))
}

@Test func commandRootUnderInterpreterNamedFromScript() throws {
  let gs = commandRoot(proc(12, ppid: 11, name: "node", path: "/Users/james/.nvm/versions/node/v22.22.0/bin/node",
                            args: ["node", "/Users/james/.nvm/versions/node/v22.22.0/bin/codex"]))
  let c = try #require(gs.first { $0.node.pid == 12 })
  #expect(c.name == "codex")
  #expect(isAITool(c, names: MemBotSettings().aiToolNames))
  let js = commandRoot(proc(12, ppid: 11, name: "node", args: ["node", "--no-warnings", "/x/cli.js", "run"]))
  #expect(js.first { $0.node.pid == 12 }?.name == "cli")
}

@Test func commandRootWithoutArgsUsesProcessName() throws {
  for args in [nil, []] as [[String]?] {
    let gs = commandRoot(proc(12, ppid: 11, name: "2.1.301", path: "/x/2.1.301", args: args))
    #expect(gs.first { $0.node.pid == 12 }?.name == "2.1.301")
  }
}
