import CryptoKit
import CustomDump
import Foundation
import Testing

private let pinnedDaemonCommit = "b0688d7d637f15f579c680efcd46416b8335142c"

private enum PinProblem: Equatable {
  case malformedLine(String)
  case unsafePath(String)
  case outOfOrder(String)
  case duplicate(String)
  case missing(String)
  case extra(String)
  case hashMismatch(String)
}

private struct Pin {
  var daemonCommit: String?
  var entries: [(sha256: String, path: String)] = []

  init(_ text: String) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let separator = lines.firstIndex(of: "---") ?? lines.endIndex
    daemonCommit = lines[..<separator].first { $0.hasPrefix("daemon-commit: ") }?.dropFirst("daemon-commit: ".count).description
    for line in lines[separator...].dropFirst() where !line.isEmpty {
      let parts = line.split(separator: "  ", maxSplits: 1).map(String.init)
      entries.append((parts.first ?? "", parts.count == 2 ? parts[1] : ""))
    }
  }

  func problems(files: [String: Data]) -> [PinProblem] {
    var problems: [PinProblem] = []
    var seen: Set<String> = []
    var previous: [UInt8] = []
    for (sha256, path) in entries {
      guard sha256.utf8.count == 64, !path.isEmpty else {
        problems.append(.malformedLine("\(sha256)  \(path)"))
        continue
      }
      if path == "PIN" || path.hasPrefix("/") || path.split(separator: "/").contains("..") {
        problems.append(.unsafePath(path))
        continue
      }
      guard seen.insert(path).inserted else {
        problems.append(.duplicate(path))
        continue
      }
      if !previous.lexicographicallyPrecedes(Array(path.utf8)) { problems.append(.outOfOrder(path)) }
      previous = Array(path.utf8)
      guard let data = files[path] else {
        problems.append(.missing(path))
        continue
      }
      if SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != sha256 {
        problems.append(.hashMismatch(path))
      }
    }
    for path in files.keys.sorted() where path != "PIN" && !seen.contains(path) {
      problems.append(.extra(path))
    }
    return problems
  }
}

struct InterfaceFixturePinTests {
  private func bundled() throws -> (pin: Pin, files: [String: Data]) {
    let files = try InterfaceFixtures.allFiles()
    let pin = Pin(String(decoding: try #require(files["PIN"]), as: UTF8.self))
    return (pin, files)
  }

  @Test func bundledFixturesMatchThePinnedDaemonCommit() throws {
    let (pin, files) = try bundled()
    expectNoDifference(pin.daemonCommit, pinnedDaemonCommit)
    expectNoDifference(pin.entries.count, 199)
    expectNoDifference(files.count, 200)
    expectNoDifference(pin.problems(files: files), [])
  }

  @Test func aChangedByteIsCaught() throws {
    let (pin, files) = try bundled()
    var mutated = files
    mutated["schema.json"]![0] ^= 0x01
    expectNoDifference(pin.problems(files: mutated), [.hashMismatch("schema.json")])
  }

  @Test func aMissingFileIsCaught() throws {
    let (pin, files) = try bundled()
    var mutated = files
    mutated["cases/ts-parameter-change/history.json"] = nil
    expectNoDifference(pin.problems(files: mutated), [.missing("cases/ts-parameter-change/history.json")])
  }

  @Test func anUnlistedFileIsCaught() throws {
    let (pin, files) = try bundled()
    var mutated = files
    mutated["cases/ts-parameter-change/events.jsonl"] = Data("{}".utf8)
    expectNoDifference(pin.problems(files: mutated), [.extra("cases/ts-parameter-change/events.jsonl")])
  }

  @Test func manifestLinesMustBeUniqueSortedAndInsideTheDirectory() throws {
    let (pin, files) = try bundled()
    var edited = pin
    let first = edited.entries[0]
    edited.entries.append(first)
    edited.entries.append((first.sha256, "../outside.json"))
    edited.entries.append((first.sha256, "PIN"))
    edited.entries.swapAt(0, 1)
    expectNoDifference(
      edited.problems(files: files),
      [.outOfOrder(pin.entries[0].path), .duplicate(first.path), .unsafePath("../outside.json"), .unsafePath("PIN")]
    )
  }

  @Test func everyCaseIsARequestAHistoryAndOneExpectation() throws {
    let files = try InterfaceFixtures.allFiles().keys.filter { $0 != "PIN" && $0 != "schema.json" }
    var shapes: [String: [String]] = [:]
    for path in files {
      let parts = path.split(separator: "/").map(String.init)
      try #require(parts.count == 3 && parts[0] == "cases", "unexpected fixture file \(path)")
      shapes[parts[1], default: []].append(parts[2])
    }
    let success = ["expected.json", "history.json", "request.txt"]
    let failure = ["expected-error.json", "history.json", "request.txt"]
    expectNoDifference(shapes.count, 66)
    expectNoDifference(shapes.values.filter { $0.sorted() == success }.count, 62)
    expectNoDifference(shapes.filter { $0.value.sorted() == failure }.keys.sorted(), [
      "range-corrupt-chain-500", "range-durable-ahead-409", "range-huge-seq", "range-invalid-request-400",
    ])
  }

  @Test func errorCasesAreHTTPExpectationsNotBodies() throws {
    struct Expectation: Decodable, Equatable {
      var http_status: Int
      var headers: [String: String]?
    }
    var expectations: [String: Expectation] = [:]
    for name in try InterfaceFixtures.caseNames() {
      let url = InterfaceFixtures.directory.appending(path: "cases/\(name)/expected-error.json")
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      expectations[name] = try JSONDecoder().decode(Expectation.self, from: Data(contentsOf: url))
    }
    expectNoDifference(expectations, [
      "range-huge-seq": Expectation(http_status: 400),
      "range-invalid-request-400": Expectation(http_status: 400),
      "range-durable-ahead-409": Expectation(http_status: 409, headers: ["slipstream-durable-seq": "4"]),
      "range-corrupt-chain-500": Expectation(http_status: 500),
    ])
  }
}
