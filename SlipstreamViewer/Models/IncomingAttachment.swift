import Foundation

/// One dropped or pasted thing, as the message box read it off the pasteboard.
enum IncomingAttachment: Equatable, Sendable {
  case file(URL)
  case image(Data)
}
