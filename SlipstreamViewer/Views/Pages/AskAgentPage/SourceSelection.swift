import Foundation
import SlipstreamCore

struct SourceSelection: Equatable {
  let sessionID: String
  let rowID: Seq
  let blockID: Int
  let firstBlockLine: Int
  let context: QuestionContext

  static func make(
    sessionID: String, row: FileChangeRow, block: CodeBlock, startY: CGFloat, endY: CGFloat
  ) -> Self? {
    guard case .content(let sha, _) = row.after, !block.lines.isEmpty,
      startY.isFinite, endY.isFinite, startY >= 0,
      startY < CGFloat(block.lines.count) * DesignTokens.Card.lineHeight
    else { return nil }
    let start = Int(startY / DesignTokens.Card.lineHeight)
    let end = Int(max(0, min(CGFloat(block.lines.count - 1), floor(endY / DesignTokens.Card.lineHeight))))
    let lines = block.lines[min(start, end)...max(start, end)]
    guard let first = lines.first, let last = lines.last,
      lines.enumerated().allSatisfy({ $0.element.id == first.id + $0.offset })
    else { return nil }
    let context = QuestionContext(changeSeq: row.id.decimal, path: row.path, snapshotSHA256: sha,
      lineStart: first.id, lineEnd: last.id)
    guard context.isValid else { return nil }
    return Self(sessionID: sessionID, rowID: row.id, blockID: block.id,
      firstBlockLine: block.lines[0].id, context: context)
  }

  func rect(in blockFrame: CGRect) -> CGRect {
    CGRect(x: blockFrame.minX,
      y: blockFrame.minY + CGFloat(context.lineStart - firstBlockLine) * DesignTokens.Card.lineHeight,
      width: blockFrame.width, height: CGFloat(context.lineEnd - context.lineStart + 1) * DesignTokens.Card.lineHeight)
  }
}

struct QuestionPlacement: Equatable {
  let modal: CGRect
  let selectionAnchor: CGPoint
  let modalAnchor: CGPoint

  init(selection: CGRect, viewport: CGRect, size: CGSize) {
    let inset = min(DesignTokens.Ask.viewportInset, min(viewport.width, viewport.height) / 2)
    let bounds = viewport.insetBy(dx: inset, dy: inset)
    let size = CGSize(width: max(0, min(size.width, bounds.width)), height: max(0, min(size.height, bounds.height)))
    let gap = DesignTokens.Ask.connectorLength
    let candidates = [
      CGPoint(x: selection.midX - size.width / 2, y: selection.maxY + gap),
      CGPoint(x: selection.midX - size.width / 2, y: selection.minY - gap - size.height),
      CGPoint(x: selection.maxX + gap, y: selection.midY - size.height / 2),
      CGPoint(x: selection.minX - gap - size.width, y: selection.midY - size.height / 2)
    ].map { point in
      CGRect(x: min(max(bounds.minX, point.x), bounds.maxX - size.width),
        y: min(max(bounds.minY, point.y), bounds.maxY - size.height), width: size.width, height: size.height)
    }
    modal = candidates.first(where: { !$0.intersects(selection) }) ?? candidates[0]
    let x = Self.closestCoordinates(selection.minX, selection.maxX, modal.minX, modal.maxX)
    let y = Self.closestCoordinates(selection.minY, selection.maxY, modal.minY, modal.maxY)
    let pairs: [(CGPoint, CGPoint)] = [
      (CGPoint(x: x.0, y: selection.maxY), CGPoint(x: x.1, y: modal.minY)),
      (CGPoint(x: x.0, y: selection.minY), CGPoint(x: x.1, y: modal.maxY)),
      (CGPoint(x: selection.maxX, y: y.0), CGPoint(x: modal.minX, y: y.1)),
      (CGPoint(x: selection.minX, y: y.0), CGPoint(x: modal.maxX, y: y.1))
    ]
    let nearest = pairs.min { Self.distance($0) < Self.distance($1) }!
    selectionAnchor = nearest.0
    modalAnchor = nearest.1
  }

  private static func closestCoordinates(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> (CGFloat, CGFloat) {
    if a1 < b0 { return (a1, b0) }
    if b1 < a0 { return (a0, b1) }
    let common = (max(a0, b0) + min(a1, b1)) / 2
    return (common, common)
  }

  private static func distance(_ pair: (CGPoint, CGPoint)) -> CGFloat {
    hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
  }
}
