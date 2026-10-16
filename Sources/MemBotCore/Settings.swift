public struct MemBotSettings: Codable, Equatable, Sendable {
  public var warnPercent: Double = 60
  public var critPercent: Double = 85
  public var cpuActivePercent: Double = 0.5
  public var diskActiveBytes: UInt64 = 65_536
  public var candidateIdleMinutes: Int = 15
  public var orphanIdleMinutes: Int = 5
  public var aiToolNames: [String] = ["claude", "codex", "ComfyUI", "Claude.app"]
  public var terminalHosts: [String] = ["Terminal", "iTerm", "iTerm2", "Ghostty", "Warp", "WezTerm", "Alacritty", "kitty", "Zed", "Visual Studio Code", "Cursor", "tmux", "herdr", "sshd", "sshd-session"]
  public var launchAtLogin: Bool = true
  public init() {}
}
