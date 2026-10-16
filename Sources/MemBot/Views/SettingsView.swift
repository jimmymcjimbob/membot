import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    Form {
      Stepper("Warn at \(Int(model.settings.warnPercent))% memory", value: $model.settings.warnPercent, in: 1...99, step: 5)
      Stepper("Critical at \(Int(model.settings.critPercent))% memory", value: $model.settings.critPercent, in: 1...100, step: 5)
      Stepper("Active above \(model.settings.cpuActivePercent.formatted())% CPU", value: $model.settings.cpuActivePercent, in: 0...100, step: 0.5)
      Stepper("Candidate after \(model.settings.candidateIdleMinutes) min idle", value: $model.settings.candidateIdleMinutes, in: 1...240)
      Stepper("Orphan after \(model.settings.orphanIdleMinutes) min idle", value: $model.settings.orphanIdleMinutes, in: 1...240)
      NameList(title: "AI tool names", names: $model.settings.aiToolNames)
      NameList(title: "Terminal hosts", names: $model.settings.terminalHosts)
      Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
      if let e = model.launchAtLoginError { Text(e).font(.caption).foregroundStyle(.red) }
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 560)
  }
}

/// One name per line. Edits go through a text buffer so a new empty line survives while typing.
private struct NameList: View {
  let title: String
  @Binding var names: [String]
  @State private var text = ""

  var body: some View {
    LabeledContent(title) {
      TextEditor(text: $text)
        .font(.body.monospaced())
        .frame(height: 80)
        .onAppear { text = names.joined(separator: "\n") }
        .onChange(of: text) { _, new in
          names = new.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
  }
}
