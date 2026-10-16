import Foundation
import ServiceManagement
import MemBotCore

enum SettingsStore {
  private static let key = "settings"

  static var hasSaved: Bool { UserDefaults.standard.data(forKey: key) != nil }

  /// Defaults on a missing or undecodable value, so a bad save never stops the app.
  static func load() -> MemBotSettings {
    guard let data = UserDefaults.standard.data(forKey: key),
          let s = try? JSONDecoder().decode(MemBotSettings.self, from: data) else { return MemBotSettings() }
    return s
  }

  static func save(_ settings: MemBotSettings) {
    if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
  }

  /// Returns the error text on failure (it fails when the app runs without a bundle).
  static func applyLaunchAtLogin(_ on: Bool) -> String? {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      return nil
    } catch { return error.localizedDescription }
  }
}
