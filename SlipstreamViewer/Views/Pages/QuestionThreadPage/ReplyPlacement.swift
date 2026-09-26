import CoreGraphics

struct ReplyPlacement {
  let popover: CGRect
  let barAnchor: CGPoint
  let popoverAnchor: CGPoint

  init(bar: CGRect, viewport: CGRect, size: CGSize) {
    let inset = DesignTokens.Reply.viewportInset
    let width = min(size.width, max(0, viewport.width - 2 * inset))
    let height = min(size.height, max(0, viewport.height - 2 * inset))
    let x = max(viewport.minX + inset, min(bar.maxX + DesignTokens.Reply.connectorLength, viewport.maxX - inset - width))
    let y = max(viewport.minY + inset, min(bar.minY, viewport.maxY - inset - height))
    popover = CGRect(x: x, y: y, width: width, height: height)
    barAnchor = CGPoint(x: bar.maxX, y: bar.midY)
    popoverAnchor = CGPoint(x: popover.minX, y: min(max(bar.midY, popover.minY), popover.maxY))
  }

  var showsConnector: Bool { popoverAnchor.x > barAnchor.x }
}
