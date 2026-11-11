import CustomDump
import Foundation
import Testing

@testable import SlipstreamCore

struct InterfaceTransportTests {
  private let descriptor = DaemonDescriptor(
    baseURL: URL(string: "http://127.0.0.1:4100")!, token: "private-token")

  @Test func cursorAndPrefixUseExactPercentEncoding() throws {
    let transport = DaemonTransport()
    let request = transport.interfaceRequest(
      descriptor, sessionID: "11111111-1111-4111-8111-111111111111",
      before: try #require(Seq("9007199254740993")),
      after: try #require(Seq("9007199254740994")),
      pathPrefix: "src/a+b ü/", afterPath: "src/a+b ü/f.ts", includeIdentical: true)
    let url = try #require(request.url)
    #expect(url.absoluteString.contains("before_seq=9007199254740993"))
    #expect(url.absoluteString.contains("after_seq=9007199254740994"))
    #expect(url.absoluteString.contains("path_prefix=src%2Fa%2Bb%20%C3%BC%2F"))
    #expect(url.absoluteString.contains("after_path=src%2Fa%2Bb%20%C3%BC%2Ff.ts"))
    #expect(url.absoluteString.contains("include_identical=true"))
    #expect(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
        $0.name == "after_path"
      }?.value == "src/a+b ü/f.ts")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-token")
  }

  @Test func textErrorsPreserveStatusAndDurableHeader() throws {
    let url = descriptor.baseURL
    for code in [400, 401, 404, 410, 500] {
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: code,
          httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"]))
      #expect(throws: DaemonHTTPError.status(code, durableSeq: nil)) {
        try DaemonTransport.check(response, body: Data())
      }
    }
    let conflict = try #require(
      HTTPURLResponse(
        url: url, statusCode: 409, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/plain", "slipstream-durable-seq": "9007199254740993"]))
    #expect(throws: DaemonHTTPError.status(409, durableSeq: Seq("9007199254740993"))) {
      try DaemonTransport.check(conflict, body: Data())
    }
  }

  @Test func statusErrorKeepsBody() throws {
    let response = try #require(
      HTTPURLResponse(url: descriptor.baseURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil))
    let body = Data("TypeError: x is undefined\n    at handler (server.js:12:3)\n".utf8) + Data([0xFF])

    #expect(
      throws: DaemonHTTPError.status(
        500, durableSeq: nil, body: "TypeError: x is undefined\n    at handler (server.js:12:3)\n\u{FFFD}")
    ) {
      try DaemonTransport.check(response, body: body)
    }
    #expect(throws: DaemonHTTPError.status(500, durableSeq: nil, body: String(repeating: "a", count: 65_536))) {
      try DaemonTransport.check(response, body: Data(repeating: UInt8(ascii: "a"), count: 70_000))
    }
  }
}
