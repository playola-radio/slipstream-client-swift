import AppKit
import Foundation
import SlipstreamCore
import SwiftUI
import Testing

@testable import SlipstreamViewer

// The one deliberate view test: a 2026-10-02 regression froze the app for ~3 s on every
// comparison layout because nested `ViewThatFits` re-measured the header's AppKit controls.
// No model property can observe layout cost, so this guards it directly with a wide budget.
@MainActor
struct FunctionChangesLayoutTests {
  private static let layoutBudget: Duration = .seconds(1)

  @Test func comparisonLaysOutWithinBudgetInsideTheFileViewer() throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Tests/SlipstreamCoreTests/Fixtures/interface-v2/cases/ts-parameter-change/expected.json")
    let page = FunctionChangesPageModel(
      comparison: try InterfaceComparison.decode(Data(contentsOf: fixture))
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }

    let firstLayout = ContinuousClock().measure {
      window.contentView = NSHostingView(rootView: FileViewerStandIn(page: page))
      window.updateConstraintsIfNeeded()
      window.contentView?.layoutSubtreeIfNeeded()
    }
    let resize = ContinuousClock().measure {
      window.setContentSize(NSSize(width: 1361, height: 799))
      window.updateConstraintsIfNeeded()
      window.contentView?.layoutSubtreeIfNeeded()
    }

    #expect(firstLayout < Self.layoutBudget, "first layout took \(firstLayout)")
    #expect(resize < Self.layoutBudget, "resize took \(resize)")
  }
}

private struct FileViewerStandIn: View {
  let page: FunctionChangesPageModel

  var body: some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: DesignTokens.FeedPane.width)
      VStack(spacing: DesignTokens.FileViewer.gap) {
        HStack {}.frame(height: DesignTokens.FileViewer.toolbarHeight)
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            Text("Function changes")
            Spacer()
            Button("Close") {}
          }
          FunctionChangesPageView(model: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .padding(DesignTokens.FileViewer.padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 1000, minHeight: 480)
  }
}
