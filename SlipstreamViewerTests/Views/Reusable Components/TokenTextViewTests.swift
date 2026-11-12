import CustomDump
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

struct TokenTextViewTests {
  @Test func typedAttachmentMarkerRequiresStorageUpdate() {
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
}
