import Sharing
import SwiftUI

enum FontSize {
  static let steps = -2...5

  static func clamped(_ step: Int) -> Int {
    min(max(step, steps.lowerBound), steps.upperBound)
  }

  static func scale(step: Int) -> CGFloat {
    scales[clamped(step) - steps.lowerBound]
  }

  private static let scales: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
}

extension SharedKey where Self == AppStorageKey<Int>.Default {
  static var fontSizeStep: Self {
    Self[.appStorage("fontSizeStep"), default: 0]
  }
}

extension EnvironmentValues {
  @Entry var fontScale: CGFloat = 1
}
