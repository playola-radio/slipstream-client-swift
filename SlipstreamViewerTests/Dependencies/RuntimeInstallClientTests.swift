import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct RuntimeInstallClientTests {
  @Test func missingShimSaysWhy() throws {
    let shim = FileManager.default.temporaryDirectory.appending(path: "\(UUID())/bin/slipstream")

    #expect(throws: ShimMissingError(path: shim.path)) { try RuntimeInstallClient.installedShim(at: shim) }
    expectNoDifference(
      ShimMissingError(path: "/rt/bin/slipstream").localizedDescription,
      "Slipstream hasn't installed its slipstream command (/rt/bin/slipstream is missing). It installs it when it "
        + "switches the recorder to its own; the recorder message says why it hasn't.")
  }

  @Test func installedShimIsItsPath() throws {
    let shim = FileManager.default.temporaryDirectory.appending(path: "slipstream-\(UUID())")
    try Data("#!/bin/sh\n".utf8).write(to: shim)
    defer { try? FileManager.default.removeItem(at: shim) }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

    expectNoDifference(try RuntimeInstallClient.installedShim(at: shim), shim.path)
  }
}
