import XCTest
@testable import AIBudget

final class LedgerBridgeTests: XCTestCase {
    func testBundledEngineParsesAndDeduplicatesOriginalSMS() throws {
        let engine = try CoreEngine()
        let state = try engine.call("initial").toDictionary()!
        let payload: [String: Any] = ["now": "2026-09-17T13:00:00Z", "id": "sample",
            "text": "[Web발신] 신한카드 승인 6,500원 스타벅스성남 09/17 09:40 누적 482,000원"]
        let first = try CoreEngine.object(engine.call("bridge", [CoreEngine.json(state), "sms", CoreEngine.json(payload)]).toString())
        let second = try CoreEngine.object(engine.call("bridge", [CoreEngine.json(first["state"]!), "sms", CoreEngine.json(payload)]).toString())
        let transactions = (second["state"] as! [String: Any])["transactions"] as! [[String: Any]]
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions[0]["amount"] as? Int, 6500)
        XCTAssertEqual(transactions[0]["store"] as? String, "스타벅스성남")
    }
    func testBridgePropagatesValidationErrors() throws {
        let engine = try CoreEngine()
        let state = try engine.call("initial").toDictionary()!
        XCTAssertThrowsError(try engine.call("bridge", [CoreEngine.json(state), "salary", "{\"amount\":-1,\"now\":\"2026-09-17T13:00:00Z\"}"]))
    }
    func testAIResponseValidationRejectsWrongTypes() throws {
        XCTAssertThrowsError(try AIClient.validate(["status": "stable", "summary": "ok", "insights": "wrong", "actions": []]))
    }
}
