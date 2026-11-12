import CustomDump
import Foundation
import SlipstreamCore
import Testing

struct AppLogLineTests {
  private let date = Date(timeIntervalSince1970: 1_794_506_584.125)

  @Test func formatsASingleLine() {
    expectNoDifference(
      AppLogLine.format(date: date, level: .error, category: "daemon", message: "sessions failed\n\n"),
      "2026-11-12T18:03:04.125Z ERROR [daemon] sessions failed\n"
    )
  }

  @Test func indentsLaterLinesOfAMultiLineMessage() {
    expectNoDifference(
      AppLogLine.format(date: date, level: .info, category: "agent", message: "pid 7 stderr: boom\nat line 2\n\nat line 4"),
      "2026-11-12T18:03:04.125Z INFO [agent] pid 7 stderr: boom\n  at line 2\n  \n  at line 4\n"
    )
  }

  @Test func redactsABearerToken() {
    let token = String(repeating: "a", count: 40)
    expectNoDifference(
      AppLogLine.format(date: date, level: .error, category: "daemon", message: "Authorization: Bearer \(token)"),
      "2026-11-12T18:03:04.125Z ERROR [daemon] Authorization: Bearer <redacted>\n"
    )
  }

  @Test func redactsAJwtShapedBearerToken() {
    let token = "abcdefghijklmnopqrstuvwxyz012345.abcdefghijklmnopqrstuvwxyz012345.abcdefghijklmnopqrstuvwxyz012345"
    let formatted = AppLogLine.format(date: date, level: .error, category: "daemon", message: "Authorization: Bearer \(token)")

    #expect(!formatted.contains(token))
    #expect(!formatted.contains(".abcdefghijklmnopqrstuvwxyz012345"))
  }
}
