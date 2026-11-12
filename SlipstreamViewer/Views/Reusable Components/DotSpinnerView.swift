import SwiftUI

struct DotSpinnerView: View {
  let spinner: DesignTokens.Sidebar.DotSpinner
  @State private var isSpinning = false

  var body: some View {
    ZStack {
      ForEach(0..<spinner.dotCount, id: \.self) { index in
        Circle()
          .fill(spinner.color)
          .frame(width: spinner.dotSize, height: spinner.dotSize)
          .opacity(spinner.opacity(ofDot: index))
          .offset(y: -(spinner.size - spinner.dotSize) / 2)
          .rotationEffect(.degrees(spinner.degrees(ofDot: index)))
      }
    }
    .frame(width: spinner.size, height: spinner.size)
    .rotationEffect(.degrees(isSpinning ? 360 : 0))
    .animation(
      .linear(duration: DesignTokens.Sidebar.DotSpinner.secondsPerTurn).repeatForever(autoreverses: false),
      value: isSpinning)
    .onAppear { isSpinning = true }
  }
}
