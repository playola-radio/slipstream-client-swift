import CustomDump
import Foundation
import SlipstreamCore
import Testing

struct WorkspacePathStreamParserTests {
  @Test func plainLine() {
    var parser = WorkspacePathStreamParser()
    expectNoDifference(parser.consume(Array("workspace_path: /a/b\n".utf8)), ["/a/b"])
  }

  @Test func splitAcrossReads() {
    var parser = WorkspacePathStreamParser()
    expectNoDifference(parser.consume(Array("works".utf8)), [])
    expectNoDifference(parser.consume(Array("pace_path: /a".utf8)), [])
    expectNoDifference(parser.consume(Array("/b\r\n".utf8)), ["/a/b"])
  }

  @Test func splitUTF8() {
    var parser = WorkspacePathStreamParser()
    let bytes = Array("workspace_path: /caf\u{E9}\n".utf8)
    let split = bytes.firstIndex(of: 0xC3)! + 1
    expectNoDifference(parser.consume(bytes[..<split]), [])
    expectNoDifference(parser.consume(bytes[split...]), ["/caf\u{E9}"])
  }

  @Test func notAtLineStart() {
    var parser = WorkspacePathStreamParser()
    expectNoDifference(parser.consume(Array("x workspace_path: /a\n".utf8)), [])
  }

  @Test func overlongLineDiscarded() {
    var parser = WorkspacePathStreamParser()
    let overlong = Array(repeating: UInt8(ascii: "x"), count: 5_000) + Array("workspace_path: /a\n".utf8)
    expectNoDifference(parser.consume(overlong), [])
    expectNoDifference(parser.consume(Array("workspace_path: /b\n".utf8)), ["/b"])
  }

  @Test func containsManagedWorkspace() {
    let root = "/h/slipstream/workspaces"
    #expect(ManagedWorkspacePath.contains("\(root)/repo/workspace-3", root: root))
    #expect(!ManagedWorkspacePath.contains("\(root)/repo/workspace-3/x", root: root))
    #expect(!ManagedWorkspacePath.contains("\(root)/workspace-3", root: root))
    #expect(!ManagedWorkspacePath.contains("/elsewhere/repo/workspace-3", root: root))
  }
}
