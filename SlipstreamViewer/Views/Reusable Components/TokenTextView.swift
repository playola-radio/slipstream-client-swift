import AppKit
import SlipstreamCore
import SwiftUI

/// Chat text whose attachment markers show as inline tokens: read-only in a sent bubble, editable
/// in the message box, where dropped or pasted files and images arrive through `onAttach`.
struct TokenTextView: NSViewRepresentable {
  let segments: [AttachmentMarker.Segment]
  let isEditable: Bool
  var onTokenTap: (String) -> Void
  var placeholder = ""
  var placeholderColor = Color.clear
  var isEnabled = true
  var onTextChange: (String) -> Void = { _ in }
  var onSubmit: () -> Void = {}
  var onDropTargetChange: (Bool) -> Void = { _ in }
  /// Identifies whose draft is shown; undo history never carries across a change.
  var draftID: UUID?
  var onAttach: ([IncomingAttachment], Int) -> Void = { _, _ in }
  @Environment(\.fontScale) private var fontScale

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let text = TokenNSTextView(usingTextLayoutManager: false)
    text.isSelectable = true
    text.importsGraphics = false
    text.drawsBackground = false
    text.textContainerInset = .zero
    text.textContainer?.lineFragmentPadding = 0
    text.textContainer?.widthTracksTextView = true
    text.insertionPointColor = NSColor(DesignTokens.Chat.Paragraph.color)
    text.allowsUndo = isEditable
    text.fontScale = fontScale
    text.typingAttributes = text.baseAttributes
    text.delegate = context.coordinator
    guard isEditable else { return text }
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.setAccessibilityLabel("Message")
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = text
    return scroll
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let text = (view as? NSScrollView)?.documentView as? TokenNSTextView ?? view as? TokenNSTextView else { return }
    context.coordinator.view = self
    text.onAttach = onAttach
    text.onDropTargetChange = onDropTargetChange
    text.isEditable = isEditable && isEnabled
    if context.coordinator.draftID != draftID {
      context.coordinator.draftID = draftID
      context.coordinator.undoManager.removeAllActions()
    }
    if text.placeholder != placeholder || text.placeholderColor != NSColor(placeholderColor) {
      text.placeholder = placeholder
      text.placeholderColor = NSColor(placeholderColor)
      text.needsDisplay = true
    }
    let currentSegments = text.segments
    let current = AttachmentMarker.text(currentSegments)
    let wanted = AttachmentMarker.text(segments)
    guard TokenNSTextView.needsStorageUpdate(
      current: currentSegments,
      wanted: segments,
      currentFontScale: text.fontScale,
      wantedFontScale: fontScale
    ) else { return }
    let caret = TokenNSTextView.caretOffset(text.draftOffset(at: text.selectedRange().location), from: current, to: wanted)
    text.fontScale = fontScale
    text.textStorage?.setAttributedString(text.attributedString(for: segments))
    text.typingAttributes = text.baseAttributes
    guard isEditable else { return }
    text.setSelectedRange(NSRange(location: text.location(forDraftOffset: caret), length: 0))
    context.coordinator.undoManager.removeAllActions()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
    guard !isEditable, let text = nsView as? NSTextView, let container = text.textContainer,
      let layout = text.layoutManager
    else { return nil }
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    return CGSize(width: ceil(used.width), height: ceil(used.height))
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var view: TokenTextView?
    var draftID: UUID?
    /// Its own undo stack, cleared whenever the model replaces the draft (send, tab switch,
    /// attach), so undo never reaches into text that is no longer there.
    let undoManager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

    func textDidChange(_ notification: Notification) {
      guard let text = notification.object as? TokenNSTextView else { return }
      view?.onTextChange(AttachmentMarker.text(text.segments))
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        textView.insertNewlineIgnoringFieldEditor(nil)
      } else {
        view?.onSubmit()
      }
      return true
    }

    func textView(
      _ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int
    ) {
      guard let token = cell.attachment as? TokenAttachment, case .attachment(_, let path) = token.segment else { return }
      view?.onTokenTap(path)
    }
  }
}

final class TokenNSTextView: NSTextView {
  var fontScale: CGFloat = 1
  var placeholder = ""
  var placeholderColor = NSColor.clear
  var onAttach: ([IncomingAttachment], Int) -> Void = { _, _ in }
  var onDropTargetChange: (Bool) -> Void = { _ in }

  var segments: [AttachmentMarker.Segment] {
    textStorage.map(Self.segments(in:)) ?? []
  }

  static func needsStorageUpdate(
    current: [AttachmentMarker.Segment], wanted: [AttachmentMarker.Segment], currentFontScale: CGFloat, wantedFontScale: CGFloat
  ) -> Bool {
    current != wanted || currentFontScale != wantedFontScale
  }

  /// Fills its scroll view however short the draft is, so a drop anywhere in that area lands here.
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard let clip = superview as? NSClipView else { return }
    clip.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: clip)
  }

  @objc private func clipResized() {
    guard let clip = superview else { return }
    minSize.height = clip.bounds.height
    sizeToFit()
  }

  /// Where a caret at draft offset `caret` belongs once `old` is replaced by `new`: a caret before
  /// the first change stays put, one at or after it moves with the text that follows.
  nonisolated static func caretOffset(_ caret: Int, from old: String, to new: String) -> Int {
    let unchanged = zip(old.utf16, new.utf16).prefix { $0 == $1 }.count
    guard caret >= unchanged else { return caret }
    return max(unchanged, caret + new.utf16.count - old.utf16.count)
  }

  var baseAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = DesignTokens.Chat.Paragraph.lineSpacing
    return [
      .font: DesignTokens.Chat.Paragraph.font.nsFont(scale: fontScale) ?? .systemFont(ofSize: 14 * fontScale),
      .foregroundColor: NSColor(DesignTokens.Chat.Paragraph.color),
      .paragraphStyle: paragraph,
    ]
  }

  func attributedString(for segments: [AttachmentMarker.Segment]) -> NSAttributedString {
    let attributes = baseAttributes
    let result = NSMutableAttributedString()
    for segment in segments {
      switch segment {
      case .text(let text):
        result.append(NSAttributedString(string: text, attributes: attributes))
      case .attachment(_, let path):
        var tokenAttributes = attributes
        tokenAttributes[.attachment] = TokenAttachment(
          segment: segment, font: attributes[.font] as? NSFont ?? .systemFont(ofSize: 14), scale: fontScale)
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

  /// The draft (marker) offset of a storage location, where each token is one character.
  func draftOffset(at location: Int) -> Int {
    guard let storage = textStorage else { return 0 }
    let prefix = storage.attributedSubstring(from: NSRange(location: 0, length: min(location, storage.length)))
    return AttachmentMarker.text(Self.segments(in: prefix)).utf16.count
  }

  /// The storage location of a draft offset; an offset inside a marker lands after its token.
  func location(forDraftOffset offset: Int) -> Int {
    var remaining = offset
    var location = 0
    for segment in segments where remaining > 0 {
      let length = AttachmentMarker.text([segment]).utf16.count
      switch segment {
      case .text: location += min(remaining, length)
      case .attachment: location += 1
      }
      remaining -= length
    }
    return location
  }

  // MARK: Copy, paste and drop

  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard let storage = textStorage else { return false }
    let text = selectedRanges.map { range in
      AttachmentMarker.text(Self.segments(in: storage.attributedSubstring(from: range.rangeValue)))
    }
    pboard.declareTypes([.string], owner: nil)
    return pboard.setString(text.joined(), forType: .string)
  }

  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
    [.fileURL, .png, .tiff, .string]
      + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
  }

  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    if attach(from: pboard, at: rangeForUserTextChange.location) { return true }
    guard let string = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
    insertText(attributedString(for: AttachmentMarker.segments(string)), replacementRange: rangeForUserTextChange)
    return true
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard isEditable, Self.canAttach(from: sender.draggingPasteboard) else { return super.draggingEntered(sender) }
    onDropTargetChange(true)
    _ = super.draggingEntered(sender)
    return .copy
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard isEditable, Self.canAttach(from: sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
    _ = super.draggingUpdated(sender)
    return .copy
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    onDropTargetChange(false)
    super.draggingExited(sender)
  }

  override func draggingEnded(_ sender: any NSDraggingInfo) {
    onDropTargetChange(false)
    super.draggingEnded(sender)
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    onDropTargetChange(false)
    let location = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
    guard isEditable, Self.canAttach(from: sender.draggingPasteboard) else { return super.performDragOperation(sender) }
    setSelectedRange(NSRange(location: location, length: 0))
    return attach(from: sender.draggingPasteboard, at: location)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    var attributes = baseAttributes
    attributes[.foregroundColor] = placeholderColor
    (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: attributes)
  }

  private static func canAttach(from pboard: NSPasteboard) -> Bool {
    pboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      || pboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
      || (pboard.availableType(from: [.png, .tiff]) != nil && pboard.availableType(from: [.string]) == nil)
  }

  /// models.md's precedence: file URLs, then promised files, then image data with no text.
  private func attach(from pboard: NSPasteboard, at location: Int) -> Bool {
    let offset = draftOffset(at: location)
    if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty
    {
      onAttach(urls.map(IncomingAttachment.file), offset)
      return true
    }
    if let receivers = pboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
      !receivers.isEmpty
    {
      receive(receivers, at: offset)
      return true
    }
    guard pboard.availableType(from: [.string]) == nil, let png = Self.pngData(from: pboard) else { return false }
    onAttach([.image(png)], offset)
    return true
  }

  /// Promised files arrive one by one; attach them together, in drag order, once every promised file has
  /// arrived, through the `onAttach` of the moment of the drop. A failed promise arrives as
  /// `unavailable` with its error. A failure to make the folder surfaces as each promise's error.
  private func receive(_ receivers: [NSFilePromiseReceiver], at offset: Int) {
    let destination = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let onAttach = onAttach
    let arrivals = PromiseArrivals(fileCounts: receivers.map { max($0.fileNames.count, 1) }) { items in onAttach(items, offset) }
    for (index, receiver) in receivers.enumerated() {
      receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { url, error in
        let item = error.map { IncomingAttachment.unavailable(name: url.lastPathComponent, detail: $0.localizedDescription) }
        MainActor.assumeIsolated { arrivals.arrived(item ?? .file(url), from: index) }
      }
    }
  }

  private static func pngData(from pboard: NSPasteboard) -> Data? {
    if let png = pboard.data(forType: .png) { return png }
    guard let tiff = pboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
    return image.representation(using: .png, properties: [:])
  }
}

@MainActor
final class PromiseArrivals {
  private var items: [[IncomingAttachment]]
  private let fileCounts: [Int]
  private let done: ([IncomingAttachment]) -> Void

  /// `fileCounts[i]` is how many files receiver `i` promised.
  init(fileCounts: [Int], done: @escaping ([IncomingAttachment]) -> Void) {
    items = Array(repeating: [], count: fileCounts.count)
    self.fileCounts = fileCounts
    self.done = done
  }

  private var isWaiting: Bool { zip(items, fileCounts).contains { $0.count < $1 } }

  func arrived(_ item: IncomingAttachment, from index: Int) {
    let wasWaiting = isWaiting
    items[index].append(item)
    if !wasWaiting {
      done([item])
    } else if !isWaiting {
      done(items.flatMap(\.self))
    }
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
  private let nameFont: NSFont
  private let nameWidth: CGFloat
  private let height: CGFloat
  private let baselineOffset: CGFloat

  init(segment: AttachmentMarker.Segment, textFont: NSFont, scale: CGFloat) {
    if case .attachment(let name, _) = segment { self.name = name } else { self.name = "" }
    icon = segment.isImage ? Token.imageIcon : Token.icon
    nameFont = Token.nameFont.nsFont(scale: scale) ?? .systemFont(ofSize: 12.5 * scale)
    nameWidth = min(ceil((name as NSString).size(withAttributes: [.font: nameFont]).width), Token.maxNameWidth)
    height = Token.height * scale
    baselineOffset = (textFont.ascender + textFont.descender - height) / 2
    super.init(textCell: "")
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var nameAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    return [.font: nameFont, .foregroundColor: NSColor(Token.nameColor), .paragraphStyle: paragraph]
  }

  override func cellSize() -> NSSize {
    NSSize(width: Token.iconCellWidth + Token.namePadding * 2 + nameWidth, height: height)
  }

  override func cellBaselineOffset() -> NSPoint {
    NSPoint(x: 0, y: baselineOffset)
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
