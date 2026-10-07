import Sharing
import SwiftUI

@MainActor
@Observable
final class FontSizeModel: ViewModel {
  // MARK: - Shared State

  @ObservationIgnored @Shared(.fontSizeStep) var step

  // MARK: - Properties

  var scale: CGFloat { FontSize.scale(step: step) }

  // MARK: - View Helpers

  var canMakeBigger: Bool { FontSize.clamped(step) < FontSize.steps.upperBound }
  var canMakeSmaller: Bool { FontSize.clamped(step) > FontSize.steps.lowerBound }
  var isActualSize: Bool { FontSize.clamped(step) == 0 }

  // MARK: - User Actions

  func biggerTapped() { $step.withLock { $0 = FontSize.clamped(FontSize.clamped($0) + 1) } }
  func smallerTapped() { $step.withLock { $0 = FontSize.clamped(FontSize.clamped($0) - 1) } }
  func actualSizeTapped() { $step.withLock { $0 = 0 } }
}
