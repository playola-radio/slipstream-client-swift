import CoreGraphics

struct ReplyPlacement {
  let popover: CGRect
  let barAnchor: CGPoint
  let popoverAnchor: CGPoint

  init(bar: CGRect, viewport: CGRect, size: CGSize) {
    let inset = DesignTokens.Reply.viewportInset
    let width = min(size.width, max(0, viewport.width - 2 * inset))
    let height = min(size.height, max(0, viewport.height - 2 * inset))
    let x = min(viewport.maxX - inset - width, max(viewport.minX + inset, bar.minX - DesignTokens.Reply.connectorLength - width))
    let y = max(viewport.minY + inset, min(bar.minY, viewport.maxY - inset - height))
    popover = CGRect(x: x, y: y, width: width, height: height)
    barAnchor = CGPoint(x: bar.minX, y: bar.midY)
    popoverAnchor = CGPoint(x: popover.maxX, y: min(max(bar.midY, popover.minY), popover.maxY))
  }

  var showsConnector: Bool { popoverAnchor.x < barAnchor.x }
}
