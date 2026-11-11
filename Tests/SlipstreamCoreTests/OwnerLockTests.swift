import CustomDump
import Testing
@testable import SlipstreamCore

struct OwnerLockTests {
  @Test(arguments: [
    (#"{"pid":30117,"nonce":"n"}"#, Int32?.some(30117)),
    ("30117\n", 30117),
    (#"{"pid":"30117"}"#, nil),
    (#"{"pid":1.5}"#, nil),
    ("", nil),
  ])
  func readsTheDaemonsLockFormats(text: String, pid: Int32?) {
    expectNoDifference(OwnerLock.pid(in: text), pid)
  }
}
