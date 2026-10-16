import SwiftUI

@main
struct MemBotApp: App {
  @State private var model: AppModel

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let m = AppModel()
    _model = State(initialValue: m)
    m.start()
  }

  var body: some Scene {
    MenuBarExtra { MenuPanel().environment(model) } label: { Image(systemName: "memorychip") }
      .menuBarExtraStyle(.window)
    Window("MemBot", id: "main") { MainWindow().environment(model) }
      .defaultSize(width: 1500, height: 900)
    Settings { SettingsView().environment(model) }
  }
}
