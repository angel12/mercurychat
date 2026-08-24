import Foundation
import Testing

@testable import MercuryKit

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("JSONValue intValue bounds")
struct JSONValueIntValueTests {
    @Test func intValueReadsIntegralNumbers() {
        #expect(JSONValue.number(42).intValue == 42)
        #expect(JSONValue.number(-7).intValue == -7)
        #expect(JSONValue.number(0).intValue == 0)
    }

    @Test func intValueRejectsFractionalNumbers() {
        #expect(JSONValue.number(1.5).intValue == nil)
    }

    // Server-controlled numbers arrive on every inbound path (RPC ids,
    // expires_at, usage counters). An integral Double beyond Int range must
    // return nil, not trap — a hostile or buggy gateway could crash the
    // client otherwise.
    @Test func intValueRejectsOutOfRangeNumbersWithoutTrapping() {
        #expect(json("1e300").intValue == nil)
        #expect(json("1e19").intValue == nil)
        #expect(json("-1e19").intValue == nil)
    }

    @Test func intValueAcceptsExactIntBounds() {
        // Double(Int.min) is exactly representable; Double(Int.max) is not
        // (it rounds up to Int.max + 1 and must be rejected).
        #expect(JSONValue.number(Double(Int.min)).intValue == Int.min)
        #expect(JSONValue.number(Double(Int.max)).intValue == nil)
    }
}
