import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SlipstreamViewer

@MainActor
struct FontSizeModelTests {
  @Test func startsAtActualSize() {
    let model = FontSizeModel()
    expectNoDifference(model.scale, 1)
    #expect(model.isActualSize)
    #expect(model.canMakeBigger)
    #expect(model.canMakeSmaller)
  }

  @Test func biggerStepsUpToTheLargestSize() {
    let model = FontSizeModel()
    var scales: [CGFloat] = []
    for _ in 1...7 {
      model.biggerTapped()
      scales.append(model.scale)
    }
    expectNoDifference(scales, [1.1, 1.25, 1.5, 1.75, 2, 2, 2])
    #expect(!model.canMakeBigger)
    #expect(!model.isActualSize)
  }

  @Test func smallerStepsDownToTheSmallestSize() {
    let model = FontSizeModel()
    var scales: [CGFloat] = []
    for _ in 1...3 {
      model.smallerTapped()
      scales.append(model.scale)
    }
    expectNoDifference(scales, [0.9, 0.8, 0.8])
    #expect(!model.canMakeSmaller)
  }

  @Test func actualSizeResetsTheScale() {
    let model = FontSizeModel()
    model.biggerTapped()
    model.biggerTapped()
    model.actualSizeTapped()
    expectNoDifference(model.scale, 1)
    #expect(model.isActualSize)
  }

  @Test func sizeIsSharedAndPersisted() {
    let model = FontSizeModel()
    model.biggerTapped()
    @Shared(.fontSizeStep) var step
    expectNoDifference(step, 1)
    expectNoDifference(FontSizeModel().scale, 1.1)
  }

  @Test func outOfRangeSavedSizeIsClamped() {
    @Shared(.fontSizeStep) var step
    $step.withLock { $0 = 40 }
    let model = FontSizeModel()
    expectNoDifference(model.scale, 2)
    #expect(!model.canMakeBigger)
    model.smallerTapped()
    expectNoDifference(model.scale, 1.75)
  }
}
