import SwiftUI
import MemBotCore
import MemBotSystem

struct MainWindow: View {
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var selection: Int32?

  var body: some View {
    @Bindable var model = model
    Group {
      if let state = model.state {
        HSplitView {
          ProcessTable(rows: rows(state), now: state.snapshot.time, selection: $selection)
            .frame(minWidth: 460)
          Group {
            if let selection { DetailPanel(pid: selection, state: state).id(selection) }
            else { Text("Select a process").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
          }
          .frame(minWidth: 300, idealWidth: 360)
        }
      } else {
        Text("Sampling…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 860, minHeight: 480)
    .searchable(text: $query, prompt: "Search name, pid, port, folder…")
    .toolbar {
      ToolbarItem {
        Picker("Filter", selection: $model.filter) {
          Text("All").tag(FilterMode.all)
          Text("Candidates · \(model.state?.evaluation.candidates.count ?? 0)").tag(FilterMode.candidates)
          Text("AI tools").tag(FilterMode.aiTools)
        }.pickerStyle(.segmented)
      }
      ToolbarItem { totals }
    }
    .onAppear { model.visibleSurfaces += 1 }
    .onDisappear { model.visibleSurfaces = max(0, model.visibleSurfaces - 1) }
  }

  private func rows(_ state: MonitorState) -> [ProcessRow] {
    let groups = filterForest(state.groups, query: query, mode: model.filter,
                              candidatePIDs: Set(state.evaluation.candidates.map(\.key.pid)),
                              aiToolNames: model.settings.aiToolNames)
    return makeRows(groups, statuses: state.evaluation.statuses, cpu: state.cpuPercent)
  }

  @ViewBuilder private var totals: some View {
    if let sys = model.state?.snapshot.system {
      let s = model.settings
      let memPct = sys.memTotal == 0 ? 0 : Double(sys.memUsed) / Double(sys.memTotal) * 100
      HStack(spacing: 8) {
        Text("Memory \(memoryLine(sys))").monospacedDigit()
        UsageBar(percent: memPct, level: usageLevel(memPct, warnAt: s.warnPercent, critAt: s.critPercent)).frame(width: 70)
        Text("CPU \(Int(sys.cpuPercent.rounded()))%").monospacedDigit()
        UsageBar(percent: sys.cpuPercent, level: usageLevel(sys.cpuPercent, warnAt: s.warnPercent, critAt: s.critPercent)).frame(width: 70)
      }.font(.system(size: 12))
    }
  }
}
