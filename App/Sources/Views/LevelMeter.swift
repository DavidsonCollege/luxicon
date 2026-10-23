import SwiftUI

/// Simple RMS level meter.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: geo.size.width * CGFloat(min(level, 1)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 48)
    }
}
