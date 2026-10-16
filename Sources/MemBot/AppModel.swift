import Foundation
import Observation
import MemBotCore
import MemBotSystem

@MainActor @Observable
final class AppModel {
  var state: MonitorState?
  var filter: FilterMode = .all
  var visibleSurfaces = 0
  var signalMessages: [ProcessKey: String] = [:]
  var launchAtLoginError: String?
  var settings: MemBotSettings {
    didSet {
      guard settings != oldValue else { return }
      SettingsStore.save(settings)
      let s = settings
      Task { await monitor.update(settings: s) }
      if s.launchAtLogin != oldValue.launchAtLogin { launchAtLoginError = SettingsStore.applyLaunchAtLogin(s.launchAtLogin) }
    }
  }

  @ObservationIgnored private let monitor: Monitor
  @ObservationIgnored private var loop: Task<Void, Never>?

  init() {
    let first = !SettingsStore.hasSaved
    let s = SettingsStore.load()
    settings = s
    monitor = Monitor(settings: s)
    if first {
      SettingsStore.save(s)
      launchAtLoginError = SettingsStore.applyLaunchAtLogin(s.launchAtLogin)
    }
  }

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let next = await self.monitor.tick()
        self.state = next
        try? await Task.sleep(for: .seconds(self.visibleSurfaces > 0 ? 1 : 5))
      }
    }
  }

  func canSignal(_ sample: ProcessSample) -> Bool { sample.uid == getuid() }

  func history(_ key: ProcessKey) async -> [HistoryPoint] { await monitor.history(key) }

  func send(_ signal: Int32, to key: ProcessKey) {
    switch sendSignal(signal, to: key) {
    case .sent: signalMessages[key] = nil
    case .processChanged: signalMessages[key] = "Process changed. Signal not sent."
    case .notPermitted: signalMessages[key] = "Not permitted."
    case .noSuchProcess: signalMessages[key] = "Process already ended."
    case .failed(let e): signalMessages[key] = "Failed (errno \(e))."
    }
  }
}
