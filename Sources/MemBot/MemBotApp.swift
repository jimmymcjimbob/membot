import SwiftUI

@main
struct MemBotApp: App {
  @State private var model = AppModel()

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra { MenuPanel().environment(model) } label: { Image(systemName: "memorychip") }
      .menuBarExtraStyle(.window)
    Window("MemBot", id: "main") { MainWindow().environment(model) }
    Settings { SettingsView().environment(model) }
  }
}
