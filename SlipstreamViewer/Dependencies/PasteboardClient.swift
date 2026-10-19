import AppKit
import Dependencies

struct PasteboardClient: Sendable {
  var copy: @Sendable (String) -> Void
}

extension PasteboardClient: DependencyKey {
  static var liveValue: Self {
    Self(copy: { text in
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    })
  }

  static var testValue: Self {
    Self(copy: unimplemented("PasteboardClient.copy"))
  }
}

extension DependencyValues {
  var pasteboard: PasteboardClient {
    get { self[PasteboardClient.self] }
    set { self[PasteboardClient.self] = newValue }
  }
}
