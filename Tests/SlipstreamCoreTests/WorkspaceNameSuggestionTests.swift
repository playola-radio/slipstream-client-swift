import CustomDump
import Foundation
import Testing

@testable import SlipstreamCore

struct WorkspaceNameSuggestionTests {
  func name(_ json: String) throws(WorkspaceNameSuggestionError) -> String? {
    try WorkspaceNameSuggestion.name(fromLine: Data(json.utf8))
  }

  @Test func resultLineGivesTheName() throws {
    expectNoDifference(
      try name(
        #"{"type":"result","subtype":"success","is_error":false,"structured_output":{"name":"Workspace Loading Indicator"}}"#),
      "Workspace Loading Indicator")
  }

  @Test func otherLinesAreSkipped() throws {
    expectNoDifference(try name(#"{"type":"system","subtype":"init"}"#), nil)
    expectNoDifference(try name("not json"), nil)
  }

  @Test func resultWithoutStructuredOutputIsBadReply() {
    #expect(throws: WorkspaceNameSuggestionError.badReply("The reply had no name.")) {
      try name(#"{"type":"result","subtype":"error_max_turns","is_error":false}"#)
    }
  }

  @Test func resultWithoutNameIsBadReply() {
    #expect(throws: WorkspaceNameSuggestionError.badReply("The reply had no name.")) {
      try name(#"{"type":"result","subtype":"success","structured_output":{"title":"x"}}"#)
    }
  }

  @Test func unusableNameIsBadReply() {
    #expect(throws: WorkspaceNameSuggestionError.badReply("The suggested name wasn't usable.")) {
      try name(#"{"type":"result","subtype":"success","structured_output":{"name":"  "}}"#)
    }
  }

  @Test func errorResultCarriesClaudesOwnText() {
    #expect(throws: WorkspaceNameSuggestionError.unavailable("Claude Code reported an error: Invalid API key")) {
      try name(#"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key"}"#)
    }
  }

  @Test(arguments: [
    ("  Fix login  ", "Fix login"), ("\"Fix login\"", "Fix login"), ("“Fix login”", "Fix login"),
    ("'Fix login'", "Fix login"), ("\"\"Fix\" login\"", "\"Fix\" login"), ("\"Fix login", "\"Fix login"),
    ("\n Fix login\n", "Fix login"), ("Don't break", "Don't break"),
  ])
  func sanitizedKeepsOneCleanName(raw: String, expected: String) {
    expectNoDifference(WorkspaceNameSuggestion.sanitized(raw), expected)
  }

  @Test(arguments: ["", "  \n", "\"\"", "Two\nlines", "Tab\there", "Bell\u{7}", "Sep\u{2028}arated"])
  func sanitizedRejectsUnusableNames(raw: String) {
    expectNoDifference(WorkspaceNameSuggestion.sanitized(raw), nil)
  }

  @Test func sanitizedAllowsSixtyFourBytesAndRejectsMore() {
    expectNoDifference(
      WorkspaceNameSuggestion.sanitized(String(repeating: "🙂", count: 16)), String(repeating: "🙂", count: 16))
    expectNoDifference(WorkspaceNameSuggestion.sanitized(String(repeating: "🙂", count: 16) + "a"), nil)
  }

  @Test func promptWrapsTheMessage() {
    expectNoDifference(
      WorkspaceNameSuggestion.prompt(for: "Add a loading spinner"),
      """
      Create a concise 2–5 word workspace name for the work described below.
      Name the work; do not answer or perform it.
      Use plain text without quotes, markdown, or ending punctuation.

      <message>
      Add a loading spinner
      </message>
      """)
  }

  @Test func promptCapsTheMessageAtEightKiBWithoutSplittingACharacter() {
    let prompt = WorkspaceNameSuggestion.prompt(for: "a" + String(repeating: "🙂", count: 3000))
    let message = prompt.components(separatedBy: "<message>\n")[1].components(separatedBy: "\n</message>")[0]

    expectNoDifference(message.utf8.count, 1 + 4 * 2047)
  }

  @Test func schemaIsOneRequiredNameString() throws {
    let schema = try #require(
      JSONSerialization.jsonObject(with: Data(WorkspaceNameSuggestion.schema.utf8)) as? NSDictionary)

    expectNoDifference(
      schema,
      [
        "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
        "additionalProperties": false,
      ] as NSDictionary)
  }
}
