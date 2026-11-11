import CustomDump
import Darwin
import Foundation
import SlipstreamCore
import Testing

struct DaemonDescriptorTests {
  @Test func validDescriptorIsFound() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate(
      #"{"url":"http://127.0.0.1:5123","token":"secret-token"}"#,
      to: runtime.appendingPathComponent("a.json"))

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.baseURL.absoluteString, "http://127.0.0.1:5123")
    expectNoDifference(descriptor.token, "secret-token")
  }

  @Test func newestByMTimeWins() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    let older = runtime.appendingPathComponent("old.json")
    let newer = runtime.appendingPathComponent("new.json")
    try writeCandidate(#"{"url":"http://127.0.0.1:1111","token":"old-token"}"#, to: older)
    try writeCandidate(#"{"url":"http://127.0.0.1:2222","token":"new-token"}"#, to: newer)
    try setModificationDate(Date(timeIntervalSince1970: 1_000), at: older)
    try setModificationDate(Date(timeIntervalSince1970: 2_000), at: newer)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "new-token")

    // Newest-by-mtime should not depend on which file is scanned first.
    try setModificationDate(Date(timeIntervalSince1970: 3_000), at: older)
    let flipped = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(flipped.token, "old-token")
  }

  @Test func mode0644Skipped() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate(
      #"{"url":"http://127.0.0.1:1234","token":"bad"}"#,
      to: runtime.appendingPathComponent("bad.json"), mode: 0o644)
    try writeGoodCandidate(in: runtime)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "good-token")
  }

  @Test func mode0640Skipped() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate(
      #"{"url":"http://127.0.0.1:1234","token":"bad"}"#,
      to: runtime.appendingPathComponent("bad.json"), mode: 0o640)
    try writeGoodCandidate(in: runtime)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "good-token")
  }

  @Test func symlinkToValidFileSkipped() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    let target = store.appendingPathComponent("target.json")
    try writeCandidate(#"{"url":"http://127.0.0.1:1234","token":"bad"}"#, to: target)
    try FileManager.default.createSymbolicLink(
      at: runtime.appendingPathComponent("link.json"), withDestinationURL: target)
    try writeGoodCandidate(in: runtime)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "good-token")
  }

  @Test func directoryNamedJSONSkipped() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try FileManager.default.createDirectory(
      at: runtime.appendingPathComponent("x.json"), withIntermediateDirectories: true)
    try writeGoodCandidate(in: runtime)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "good-token")
  }

  @Test func wrongOwnerSkipped() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeGoodCandidate(in: runtime)

    try expectNoDaemonRunning(store: store, currentUID: getuid() + 1)
  }

  @Test func nonJSONFilesIgnored() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try "not even json".write(
      to: runtime.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try writeGoodCandidate(in: runtime)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "good-token")
  }

  @Test func malformedJSONSkipped() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate("{not json", to: runtime.appendingPathComponent("bad.json"))
    try writeGoodCandidate(in: runtime)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "good-token")
  }

  @Test func missingTokenSkipped() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate(#"{"url":"http://127.0.0.1:1234"}"#, to: runtime.appendingPathComponent("bad.json"))
    try writeGoodCandidate(in: runtime)

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.token, "good-token")
  }

  @Test(
    arguments: [
      "http://127.0.0.1:5123",
      "http://127.0.0.1:5123/",
      "http://localhost:5123",
      "http://[::1]:5123",
    ]
  )
  func acceptedURLs(_ urlString: String) throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate(
      #"{"url":"\#(urlString)","token":"t"}"#, to: runtime.appendingPathComponent("a.json"))

    let descriptor = try DescriptorDiscovery.discover(store: store)
    expectNoDifference(descriptor.baseURL.absoluteString, urlString)
  }

  @Test(
    arguments: [
      "https://127.0.0.1:5123",
      "http://10.0.0.1:5123",
      "http://example.com:5123",
      "http://user:pass@127.0.0.1:5123",
      "http://127.0.0.1:5123/path",
      "http://127.0.0.1:5123?x=1",
      "http://127.0.0.1:5123#frag",
      "http://127.0.0.1",
    ]
  )
  func rejectedURLs(_ urlString: String) throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate(
      #"{"url":"\#(urlString)","token":"t"}"#, to: runtime.appendingPathComponent("a.json"))

    try expectNoDaemonRunning(store: store)
  }

  @Test func missingRuntimeDirReportsErrno() throws {
    let store = try makeStore()
    let runtime = store.appendingPathComponent("runtime").path

    #expect(throws: DescriptorError.noRuntimeDirectory(path: runtime, errno: ENOENT, message: "No such file or directory")) {
      try DescriptorDiscovery.discover(store: store)
    }
  }

  @Test func rejectedDescriptorsListEachReason() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    try writeCandidate(
      #"{"url":"http://127.0.0.1:1234","token":"t"}"#, to: runtime.appendingPathComponent("a.json"), mode: 0o644)
    try writeCandidate(
      #"{"url":"http://10.0.0.2:4100","token":"t"}"#, to: runtime.appendingPathComponent("b.json"))

    #expect(
      throws: DescriptorError.noUsableDescriptor(
        directory: runtime.path,
        rejected: [
          DescriptorRejection(file: "a.json", reason: "mode 0644 (group/other bits set)"),
          DescriptorRejection(file: "b.json", reason: "url is not loopback: http://10.0.0.2:4100"),
        ])
    ) {
      try DescriptorDiscovery.discover(store: store)
    }
    #expect(
      throws: DescriptorError.noUsableDescriptor(
        directory: runtime.path,
        rejected: [
          DescriptorRejection(file: "a.json", reason: "mode 0644 (group/other bits set)"),
          DescriptorRejection(file: "b.json", reason: "owner uid \(getuid()), expected \(getuid() + 1)"),
        ])
    ) {
      try DescriptorDiscovery.discover(store: store, currentUID: getuid() + 1)
    }
  }

  @Test func rejectionNeverContainsToken() throws {
    let store = try makeStore()
    let runtime = try makeRuntimeDir(in: store)
    let token = "tok-5f1c2e9a7b3d4c6e8f0a1b2c3d4e5f60"
    let candidates = [
      #"{"url":"http://10.0.0.2:4100/\#(token)","token":"\#(token)"}"#,
      #"{"url":"http://\#(token):4100","token":"\#(token)"}"#,
      #"{"url":"http://\#(token):\#(token)@127.0.0.1:4100","token":"\#(token)"}"#,
      #"{"url":"http://127.0.0.1:4100/\#(token)","token":"\#(token)"}"#,
      #"{"url":"http://127.0.0.1:4100?t=\#(token)","token":"\#(token)"}"#,
      #"{"url":"http://127.0.0.1:4100#\#(token)","token":"\#(token)"}"#,
      #"{"url":"\#(token)","token":"\#(token)"}"#,
      #"{"url":"http://127.0.0.1:4100","token":"\#(token)""#,
      #"{"url":["\#(token)"],"token":"\#(token)"}"#,
    ]
    for (index, json) in candidates.enumerated() {
      try writeCandidate(json, to: runtime.appendingPathComponent("\(index).json"))
    }

    do {
      _ = try DescriptorDiscovery.discover(store: store)
      Issue.record("expected discover to throw")
    } catch {
      guard case .noUsableDescriptor(_, let rejected) = error else {
        Issue.record("unexpected \(error)")
        return
      }
      expectNoDifference(rejected.count, candidates.count)
      #expect(!String(describing: error).contains(token))
      #expect(!String(customDumping: error).contains(token))
    }
  }

  @Test func storeURLDefaultsToHomeDotSlipstream() {
    let home = URL(fileURLWithPath: "/Users/testuser")
    let url = DescriptorDiscovery.storeURL(environment: [:], home: home)
    expectNoDifference(url.path, "/Users/testuser/.slipstream")
  }

  @Test func storeURLUsesEnvironmentOverride() {
    let home = URL(fileURLWithPath: "/Users/testuser")
    let url = DescriptorDiscovery.storeURL(environment: ["SLIPSTREAM_STORE": "/custom/store"], home: home)
    expectNoDifference(url.path, "/custom/store")
  }

  @Test func storeURLExpandsTilde() {
    let home = URL(fileURLWithPath: "/Users/testuser")
    let url = DescriptorDiscovery.storeURL(environment: ["SLIPSTREAM_STORE": "~/custom"], home: home)
    expectNoDifference(url.path, "/Users/testuser/custom")
  }

  @Test func storeURLIgnoresEmptyEnvironmentValue() {
    let home = URL(fileURLWithPath: "/Users/testuser")
    let url = DescriptorDiscovery.storeURL(environment: ["SLIPSTREAM_STORE": ""], home: home)
    expectNoDifference(url.path, "/Users/testuser/.slipstream")
  }

  @Test func descriptionsRedactTheToken() {
    let descriptor = DaemonDescriptor(
      baseURL: URL(string: "http://127.0.0.1:5123")!, token: "super-secret-token")
    #expect(!descriptor.description.contains(descriptor.token))
    #expect(!descriptor.debugDescription.contains(descriptor.token))
    #expect(!String(customDumping: descriptor).contains(descriptor.token))
  }
}

// MARK: - Helpers

private func makeStore() throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("DaemonDescriptorTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func makeRuntimeDir(in store: URL) throws -> URL {
  let runtime = store.appendingPathComponent("runtime")
  try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
  return runtime
}

private func writeCandidate(_ json: String, to url: URL, mode: Int = 0o600) throws {
  try json.write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func writeGoodCandidate(in runtime: URL) throws {
  try writeCandidate(
    #"{"url":"http://127.0.0.1:9999","token":"good-token"}"#,
    to: runtime.appendingPathComponent("zzz-good.json"))
}

private func setModificationDate(_ date: Date, at url: URL) throws {
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func expectNoDaemonRunning(store: URL, currentUID: uid_t = getuid()) throws {
  do {
    _ = try DescriptorDiscovery.discover(store: store, currentUID: currentUID)
    Issue.record("expected discover to throw noUsableDescriptor")
  } catch {
    guard case .noUsableDescriptor(let directory, let rejected) = error else {
      Issue.record("unexpected \(error)")
      return
    }
    expectNoDifference(directory, store.appendingPathComponent("runtime").path)
    #expect(!rejected.isEmpty)
  }
}
