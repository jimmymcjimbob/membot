import SwiftUI
import Charts
import MemBotCore

/// Memory (top) and CPU (bottom) for the last 10 minutes, on one shared time axis.
struct UsageGraph: View {
  let points: [HistoryPoint]
  let end: Date
  let footprint: UInt64?

  // Fixed width for the y labels: both plot areas then have the same width, so the time marks line up.
  private static let labelWidth: CGFloat = 52

  var body: some View {
    let domain = end.addingTimeInterval(-600)...end
    let mem = memAxis
    VStack(alignment: .leading, spacing: 8) {
      Chart(points, id: \.time) {
        LineMark(x: .value("Time", $0.time), y: .value("MB", Double($0.footprint) / 1_048_576))
          .foregroundStyle(Color(red: 0x5a / 255, green: 0xa9 / 255, blue: 1))
      }
      .chartXScale(domain: domain)
      .chartXAxis { timeAxis(labels: false) }
      .chartYScale(domain: Self.inset(mem.lo...mem.hi))
      .chartYAxis { valueAxis(mem.marks) { formatBytes(UInt64($0 * 1_048_576)) } }
      .frame(height: 80)
      Chart(points, id: \.time) {
        LineMark(x: .value("Time", $0.time), y: .value("CPU %", $0.cpuPercent))
          .foregroundStyle(Color(red: 0x3f / 255, green: 0xb9 / 255, blue: 0x6b / 255))
      }
      .chartXScale(domain: domain)
      .chartXAxis { timeAxis(labels: true) }
      .chartYScale(domain: Self.inset(0...cpuTop))
      .chartYAxis { valueAxis([0, cpuTop / 2, cpuTop]) { "\(Int($0.rounded()))%" } }
      .frame(height: 70)
      Text("memory \(footprint.map(formatBytes) ?? "not available") · CPU \(points.last.map { "\(Int($0.cpuPercent.rounded()))%" } ?? "not available")")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
  }

  // Same time marks on both charts; labels only under the lower one.
  private func timeAxis(labels: Bool) -> some AxisContent {
    AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
      AxisGridLine()
      if labels { AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    }
  }

  // Explicit domains and three explicit marks: automatic marks vanish on flat data
  // (e.g. 0% CPU), which changed the label width and so the plot width.
  // Three round marks (1/2/5 × 10ⁿ MB apart, at least 1 MB) that cover the data.
  private var memAxis: (lo: Double, hi: Double, marks: [Double]) {
    let mb = points.map { Double($0.footprint) / 1_048_576 }
    let lo = mb.min() ?? 0, hi = mb.max() ?? 0
    var step = max(1, Self.nice((hi - lo) / 2))
    var a = (lo / step).rounded(.down) * step
    while a + 2 * step < hi {
      step = Self.nice(step * 1.5)
      a = (lo / step).rounded(.down) * step
    }
    return (a, a + 2 * step, [a, a + step, a + 2 * step])
  }

  // 12% margin above and below the outer marks, so their labels stay inside the chart.
  private static func inset(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
    let m = (r.upperBound - r.lowerBound) * 0.12
    return (r.lowerBound - m)...(r.upperBound + m)
  }

  private static func nice(_ x: Double) -> Double {
    guard x > 0 else { return 1 }
    let p = pow(10, (log10(x)).rounded(.down))
    let f = x / p
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p
  }

  private var cpuTop: Double {
    let peak = points.map(\.cpuPercent).max() ?? 0
    return max(100, (peak / 50).rounded(.up) * 50)
  }

  private func valueAxis(_ marks: [Double], _ label: @escaping (Double) -> String) -> some AxisContent {
    AxisMarks(position: .trailing, values: marks) { value in
      AxisGridLine()
      AxisValueLabel {
        if let v = value.as(Double.self) {
          Text(label(v)).frame(width: Self.labelWidth, alignment: .trailing)
        }
      }
    }
  }
}
