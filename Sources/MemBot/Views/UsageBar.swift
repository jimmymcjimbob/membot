import SwiftUI
import MemBotCore

struct UsageBar: View {
  let percent: Double
  let level: UsageLevel

  private var color: Color {
    switch level {
    case .ok: Color(red: 0x3f / 255, green: 0xb9 / 255, blue: 0x6b / 255)
    case .warn: Color(red: 0xf0 / 255, green: 0xa4 / 255, blue: 0x3a / 255)
    case .crit: Color(red: 0xe5 / 255, green: 0x48 / 255, blue: 0x4d / 255)
    }
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(color).frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
      }
    }
    .frame(height: 6)
  }
}
