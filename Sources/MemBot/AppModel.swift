import Foundation
import Observation
import MemBotCore
import MemBotSystem

@MainActor @Observable
final class AppModel {
  var state: MonitorState?
  var filter: FilterMode = .all
  var visibleSurfaces = 0 {
    didSet { if oldValue == 0, visibleSurfaces > 0 { nap?.cancel() } } // wake the loop so an opened surface gets fresh data
  }
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
  @ObservationIgnored private var nap: Task<Void, Never>?

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
        // Set before each tick (not from didSet) so a wake-up tick already sees the new visibility.
        await self.monitor.setVisible(self.visibleSurfaces > 0)
        let next = await self.monitor.tick()
        self.state = next
        let seconds = self.visibleSurfaces > 0 ? 1 : 5
        let nap = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        self.nap = nap
        await nap.value
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
