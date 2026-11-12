import AppKit
import SlipstreamCore
import SwiftUI

/// Chat text whose attachment markers show as inline tokens. Read-only in a sent bubble.
struct TokenTextView: NSViewRepresentable {
  let segments: [AttachmentMarker.Segment]
  let isEditable: Bool
  var onTokenTap: (String) -> Void
  @Environment(\.fontScale) private var fontScale

  func makeCoordinator() -> Coordinator { Coordinator(onTokenTap: onTokenTap) }

  func makeNSView(context: Context) -> NSView {
    let text = TokenNSTextView(usingTextLayoutManager: false)
    text.isEditable = isEditable
    text.isSelectable = true
    text.importsGraphics = false
    text.drawsBackground = false
    text.textContainerInset = .zero
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = true
    text.delegate = context.coordinator
    return text
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let text = view as? TokenNSTextView else { return }
    context.coordinator.onTokenTap = onTokenTap
    guard text.segments != segments || text.fontScale != fontScale else { return }
    text.fontScale = fontScale
    text.textStorage?.setAttributedString(text.attributedString(for: segments))
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
    guard let text = nsView as? NSTextView, let container = text.textContainer, let layout = text.layoutManager
    else { return nil }
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    return CGSize(width: ceil(used.width), height: ceil(used.height))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var onTokenTap: (String) -> Void

    init(onTokenTap: @escaping (String) -> Void) { self.onTokenTap = onTokenTap }

    func textView(
      _ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int
    ) {
      guard let token = cell.attachment as? TokenAttachment, case .attachment(_, let path) = token.segment else { return }
      onTokenTap(path)
    }
  }
}

final class TokenNSTextView: NSTextView {
  var fontScale: CGFloat = 1

  var segments: [AttachmentMarker.Segment] {
    textStorage.map(Self.segments(in:)) ?? []
  }

  func attributedString(for segments: [AttachmentMarker.Segment]) -> NSAttributedString {
    let font = DesignTokens.Chat.Paragraph.font.nsFont(scale: fontScale) ?? .systemFont(ofSize: 14 * fontScale)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = DesignTokens.Chat.Paragraph.lineSpacing
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor(DesignTokens.Chat.Paragraph.color),
      .paragraphStyle: paragraph,
    ]
    let result = NSMutableAttributedString()
    for segment in segments {
      switch segment {
      case .text(let text):
        result.append(NSAttributedString(string: text, attributes: attributes))
      case .attachment(_, let path):
        var tokenAttributes = attributes
        tokenAttributes[.attachment] = TokenAttachment(segment: segment, font: font, scale: fontScale)
        tokenAttributes[.toolTip] = path
        result.append(NSAttributedString(string: "\u{FFFC}", attributes: tokenAttributes))
      }
    }
    return result
  }

  static func segments(in string: NSAttributedString) -> [AttachmentMarker.Segment] {
    var segments: [AttachmentMarker.Segment] = []
    var text = ""
    string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, range, _ in
      guard let token = value as? TokenAttachment else {
        text += (string.string as NSString).substring(with: range)
        return
      }
      if !text.isEmpty { segments.append(.text(text)) }
      text = ""
      segments.append(contentsOf: repeatElement(token.segment, count: range.length))
    }
    if !text.isEmpty { segments.append(.text(text)) }
    return segments
  }

  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard let storage = textStorage else { return false }
    let text = selectedRanges.map { range in
      AttachmentMarker.text(Self.segments(in: storage.attributedSubstring(from: range.rangeValue)))
    }
    pboard.declareTypes([.string], owner: nil)
    return pboard.setString(text.joined(), forType: .string)
  }
}

final class TokenAttachment: NSTextAttachment {
  let segment: AttachmentMarker.Segment

  @MainActor init(segment: AttachmentMarker.Segment, font: NSFont, scale: CGFloat) {
    self.segment = segment
    super.init(data: nil, ofType: nil)
    attachmentCell = TokenCell(segment: segment, textFont: font, scale: scale)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class TokenCell: NSTextAttachmentCell {
  private typealias Token = DesignTokens.Chat.Attachment
  private let name: String
  private let icon: DesignTokens.Icons.Icon
  private let textFont: NSFont
  private let nameFont: NSFont

  init(segment: AttachmentMarker.Segment, textFont: NSFont, scale: CGFloat) {
    if case .attachment(let name, _) = segment { self.name = name } else { self.name = "" }
    icon = segment.isImage ? Token.imageIcon : Token.icon
    self.textFont = textFont
    nameFont = Token.nameFont.nsFont(scale: scale) ?? .systemFont(ofSize: 12.5 * scale)
    super.init(textCell: "")
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var nameAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    return [.font: nameFont, .foregroundColor: NSColor(Token.nameColor), .paragraphStyle: paragraph]
  }

  private var nameWidth: CGFloat {
    min(ceil((name as NSString).size(withAttributes: [.font: nameFont]).width), Token.maxNameWidth)
  }

  override func cellSize() -> NSSize {
    NSSize(width: Token.iconCellWidth + Token.namePadding * 2 + nameWidth, height: Token.height)
  }

  override func cellBaselineOffset() -> NSPoint {
    NSPoint(x: 0, y: (textFont.ascender + textFont.descender - Token.height) / 2)
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    let box = cellFrame.insetBy(dx: Token.strokeWidth / 2, dy: Token.strokeWidth / 2)
    let outline = NSBezierPath(roundedRect: box, xRadius: Token.radius, yRadius: Token.radius)
    NSColor(Token.fill).setFill()
    outline.fill()
    NSColor(Token.stroke).setStroke()
    outline.lineWidth = Token.strokeWidth
    outline.stroke()

    NSColor(Token.stroke).setFill()
    NSRect(x: cellFrame.minX + Token.iconCellWidth, y: cellFrame.minY, width: Token.strokeWidth, height: cellFrame.height)
      .fill()

    if let image = NSImage(named: icon.assetName) {
      let iconRect = NSRect(
        x: cellFrame.minX + (Token.iconCellWidth - icon.size) / 2,
        y: cellFrame.midY - icon.size / 2,
        width: icon.size,
        height: icon.size
      )
      tinted(image, size: iconRect.size).draw(
        in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
      )
    }

    let lineHeight = ceil(nameFont.ascender - nameFont.descender)
    let nameRect = NSRect(
      x: cellFrame.minX + Token.iconCellWidth + Token.namePadding,
      y: cellFrame.midY - lineHeight / 2,
      width: nameWidth,
      height: lineHeight
    )
    (name as NSString).draw(in: nameRect, withAttributes: nameAttributes)
  }

  override func wantsToTrackMouse() -> Bool { true }

  override func accessibilityLabel() -> String? { name }

  private func tinted(_ image: NSImage, size: NSSize) -> NSImage {
    let color = NSColor(icon.color)
    return NSImage(size: size, flipped: false) { rect in
      image.draw(in: rect)
      color.set()
      rect.fill(using: .sourceAtop)
      return true
    }
  }
}
