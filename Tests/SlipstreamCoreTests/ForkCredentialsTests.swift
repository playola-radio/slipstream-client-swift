import CustomDump
import Foundation
import SlipstreamCore
import Testing

struct ForkCredentialsTests {
  func credentials(_ json: String) throws(ForkCredentialsError) -> ForkCredentials {
    try ForkCredentials(userSettings: Data(json.utf8))
  }

  @Test func keepsEnvAndCredentialHelpersOnly() throws {
    let settings = """
      {"env":{"CLAUDE_CODE_USE_BEDROCK":"1","NODE_EXTRA_CA_CERTS":"/certs/corp.pem","PATH":"/corp/bin"},
       "apiKeyHelper":"/opt/bin/key","awsAuthRefresh":"aws sso login","otelHeadersHelper":"/opt/bin/otel",
       "hooks":{"PostToolUse":[]},"permissions":{"allow":["Bash"]},"model":"opus","enabledPlugins":{}}
      """
    expectNoDifference(
      try credentials(settings),
      ForkCredentials(
        environment: ["CLAUDE_CODE_USE_BEDROCK": "1", "NODE_EXTRA_CA_CERTS": "/certs/corp.pem"],
        settings: #"{"apiKeyHelper":"/opt/bin/key","awsAuthRefresh":"aws sso login","env":{"PATH":"/corp/bin"}}"#
      )
    )
  }

  @Test func keepsEveryCredentialHelper() throws {
    let settings = """
      {"apiKeyHelper":"a","awsAuthRefresh":"b","awsCredentialExport":"c","gcpAuthRefresh":"d"}
      """
    expectNoDifference(
      try credentials(settings).settings,
      #"{"apiKeyHelper":"a","awsAuthRefresh":"b","awsCredentialExport":"c","gcpAuthRefresh":"d"}"#
    )
  }

  @Test func settingsWithoutCredentialsAreNone() throws {
    expectNoDifference(try credentials(#"{"hooks":{},"model":"opus"}"#), .none)
  }

  @Test func invalidJSONIsAnError() {
    #expect(throws: ForkCredentialsError(reason: "it isn't a JSON object")) { try credentials("{not json") }
    #expect(throws: ForkCredentialsError(reason: "it isn't a JSON object")) { try credentials("[]") }
  }

  @Test func envThatIsntAnObjectIsAnError() {
    #expect(throws: ForkCredentialsError(reason: "its env isn't an object")) { try credentials(#"{"env":"x"}"#) }
  }

  @Test func envValueThatIsntTextNamesTheVariable() {
    #expect(throws: ForkCredentialsError(reason: "its env value for MAX_TOKENS isn't text")) {
      try credentials(#"{"env":{"OK":"1","MAX_TOKENS":4096}}"#)
    }
  }

  @Test func helperThatIsntTextNamesTheSetting() {
    #expect(throws: ForkCredentialsError(reason: "its apiKeyHelper isn't text")) {
      try credentials(#"{"apiKeyHelper":true}"#)
    }
  }
}
