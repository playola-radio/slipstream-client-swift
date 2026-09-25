import CustomDump
import Dependencies
import Foundation
import SlipstreamCore
import Testing
@testable import SlipstreamViewer

@MainActor
struct SourceSelectionTests {
  let row = FileChangeRow(id: Seq("12")!, path: "user.ts", before: .absent,
    after: .content(sha256: String(repeating: "a", count: 64), size: 100), time: "12:00")
  let block = CodeBlock(id: 0, separatorText: "···", lines: [
    CodeLine(id: 7, number: "7", text: "  text", isChanged: true),
    CodeLine(id: 8, number: "8", text: "", isChanged: false),
    CodeLine(id: 9, number: "9", text: "end", isChanged: true)
  ], truncationText: "… truncated")

  @Test func reverseDragMapsOnlyActualContiguousSourceRows() {
    let selected = SourceSelection.make(sessionID: "capture", row: row, block: block, startY: 53, endY: 2)
    expectNoDifference(selected?.context.lineStart, 7)
    expectNoDifference(selected?.context.lineEnd, 9)
    expectNoDifference(selected?.context.changeSeq, "12")
    expectNoDifference(selected?.context.snapshotSHA256, String(repeating: "a", count: 64))
    #expect(SourceSelection.make(sessionID: "capture", row: row, block: block, startY: -1, endY: 20) == nil)
    #expect(SourceSelection.make(sessionID: "capture", row: row, block: block, startY: 66, endY: 20) == nil)
    var disjoint = block
    disjoint.lines.remove(at: 1)
    #expect(SourceSelection.make(sessionID: "capture", row: row, block: disjoint, startY: 1, endY: 30) == nil)
    var absent = row
    absent.after = .absent
    #expect(SourceSelection.make(sessionID: "capture", row: absent, block: block, startY: 1, endY: 30) == nil)
  }

  @Test func geometryClampsAtEveryViewportEdgeAndJoinsBoundaries() {
    let viewport = CGRect(x: 0, y: 0, width: 1100, height: 800)
    for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: 0, y: 740), CGPoint(x: 1000, y: 740)] {
      let selection = CGRect(origin: origin, size: CGSize(width: 80, height: 44))
      let placement = QuestionPlacement(selection: selection, viewport: viewport, size: CGSize(width: 640, height: 396))
      #expect(viewport.contains(placement.modal))
      #expect(onBoundary(placement.selectionAnchor, selection))
      #expect(onBoundary(placement.modalAnchor, placement.modal))
    }
  }

  @Test func resizeAndScrollRepositionWithoutChangingContext() {
    let initial = QuestionPlacement(selection: CGRect(x: 20, y: 100, width: 400, height: 44),
      viewport: CGRect(x: 0, y: 0, width: 1100, height: 800), size: CGSize(width: 640, height: 396))
    let scrolled = QuestionPlacement(selection: CGRect(x: 20, y: 200, width: 400, height: 44),
      viewport: CGRect(x: 0, y: 0, width: 1100, height: 800), size: CGSize(width: 640, height: 396))
    expectNoDifference(scrolled.modal.minY - initial.modal.minY, 100)
    let small = CGRect(x: 0, y: 0, width: 600, height: 300)
    let resized = QuestionPlacement(selection: CGRect(x: 20, y: 200, width: 400, height: 44),
      viewport: small, size: CGSize(width: 640, height: 532))
    #expect(small.contains(resized.modal))
  }

  private func onBoundary(_ point: CGPoint, _ rect: CGRect) -> Bool {
    let horizontal = (point.x == rect.minX || point.x == rect.maxX) && point.y >= rect.minY && point.y <= rect.maxY
    let vertical = (point.y == rect.minY || point.y == rect.maxY) && point.x >= rect.minX && point.x <= rect.maxX
    return horizontal || vertical
  }
}

extension SourceSelectionTests {
  @Test func verticalConnectorUsesTheShortestBoundaryDistance() {
    let placement = QuestionPlacement(selection: CGRect(x: 20, y: 100, width: 400, height: 44),
      viewport: CGRect(x: 0, y: 0, width: 1100, height: 800), size: CGSize(width: 640, height: 396))
    expectNoDifference(placement.selectionAnchor.x, placement.modalAnchor.x)
    expectNoDifference(placement.modalAnchor.y - placement.selectionAnchor.y, DesignTokens.Ask.connectorLength)
  }
}
