import CustomDump
import SlipstreamCore
import Testing

struct SeqTests {
  @Test func acceptsCanonicalDecimals() {
    expectNoDifference(Seq("1")?.decimal, "1")
    expectNoDifference(Seq("0")?.decimal, "0")
    expectNoDifference(Seq("123456789012345678901234567890")?.decimal, "123456789012345678901234567890")
  }

  @Test func rejectsNonCanonicalInput() {
    #expect(Seq("") == nil)
    #expect(Seq("01") == nil)
    #expect(Seq("-1") == nil)
    #expect(Seq("1.0") == nil)
    #expect(Seq(" 1") == nil)
    #expect(Seq("١") == nil)
  }

  @Test func successorCarriesBeyondUInt64() {
    expectNoDifference(Seq("18446744073709551615")?.successor.decimal, "18446744073709551616")
    expectNoDifference(Seq("999")?.successor.decimal, "1000")
    expectNoDifference(Seq("0")?.successor.decimal, "1")
    expectNoDifference(Seq("129")?.successor.decimal, "130")
  }

  @Test func comparesNumericallyNotLexically() throws {
    #expect(try #require(Seq("9")) < #require(Seq("10")))
    #expect(try #require(Seq("18446744073709551616")) > #require(Seq("18446744073709551615")))
    #expect(try #require(Seq("20")) > #require(Seq("19")))
    #expect(try !(#require(Seq("7")) < #require(Seq("7"))))
  }
}
