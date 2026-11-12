import AppKit
import CustomDump
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

struct TokenTextViewTests {
  @MainActor @Test func typedAttachmentMarkerRequiresStorageUpdate() {
    let marker = "@⟦a.md⟧(/tmp/a.md)"

    expectNoDifference(
      TokenNSTextView.needsStorageUpdate(
        current: [.text(marker)],
        wanted: AttachmentMarker.segments(marker),
        currentFontScale: 1,
        wantedFontScale: 1
      ),
      true
    )
  }

  @MainActor @Test func attachmentBadgeScalesWithTheText() {
    let attachment = TokenAttachment(
      segment: .attachment(name: "a.md", path: "/tmp/a.md"),
      font: .systemFont(ofSize: 28),
      scale: 2
    )

    expectNoDifference(attachment.attachmentCell?.cellSize().height, 48)
  }

  @Test func caretBeforeAnInsertStays() {
    expectNoDifference(TokenNSTextView.caretOffset(1, from: "hello", to: "hello world"), 1)
  }

  @Test func caretAfterAnInsertMovesWithIt() {
    expectNoDifference(TokenNSTextView.caretOffset(5, from: "hello", to: "big hello"), 9)
  }

  @Test func caretAfterAReplacementGoesToTheEnd() {
    expectNoDifference(TokenNSTextView.caretOffset(5, from: "hello", to: ""), 0)
  }

  @MainActor @Test func promisesWaitForEveryFileOfEachReceiver() {
    var delivered: [[IncomingAttachment]] = []
    let arrivals = PromiseArrivals(fileCounts: [2, 1]) { delivered.append($0) }
    let a = URL(filePath: "/tmp/a.png")
    let c = URL(filePath: "/tmp/c.png")
    arrivals.arrived(.unavailable(name: "b.png", detail: "failed"), from: 0)
    arrivals.arrived(.file(c), from: 1)
    arrivals.arrived(.file(a), from: 0)
    expectNoDifference(delivered, [[.unavailable(name: "b.png", detail: "failed"), .file(a), .file(c)]])
  }

  @MainActor @Test func droppingAFinderFileAttachesIt() {
    let file = URL(filePath: "/tmp/my note (1).txt")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    let drag = FakeDrag(pasteboard: pasteboard)
    let text = TokenNSTextView(usingTextLayoutManager: false)
    text.importsGraphics = false
    var attached: [IncomingAttachment] = []
    text.onAttach = { items, _, _ in attached += items }

    _ = text.draggingEntered(drag)
    _ = text.draggingUpdated(drag)
    let accepted = text.prepareForDragOperation(drag) && text.performDragOperation(drag)

    #expect(accepted)
    expectNoDifference(attached, [.file(file)])
  }
}

@MainActor
private final class FakeDrag: NSObject, @MainActor NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggingLocation: NSPoint { .zero }
  var draggedImageLocation: NSPoint { .zero }
  var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func resetSpringLoading() {}
}
