import SwiftUI
import MemBotCore

struct SignalButtons: View {
  @Environment(AppModel.self) private var model
  let key: ProcessKey
  let name: String
  let canSignal: Bool
  let compact: Bool
  @State private var confirmKill = false

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      HStack(spacing: 4) {
        Button(compact ? "Term" : "Send SIGTERM") { model.send(SIGTERM, to: key) }
        Button(compact ? "Kill" : "Send SIGKILL") { confirmKill = true }
          .tint(.red)
      }
      .controlSize(.small)
      .disabled(!canSignal)
      .help(canSignal ? "" : "MemBot can only signal your own processes.")
      if let msg = model.signalMessages[key] {
        Text(msg).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .confirmationDialog("Kill \(name) (pid \(key.pid))?", isPresented: $confirmKill) {
      Button("Kill", role: .destructive) { model.send(SIGKILL, to: key) }
    }
  }
}
