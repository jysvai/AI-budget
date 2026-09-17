import XCTest
import UIKit
@testable import AIBudget

final class LedgerBridgeTests: XCTestCase {
    func testPretendardFontIsBundled() {
        XCTAssertNotNil(UIFont(name: "PretendardVariable-Regular", size: 17))
    }

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

    func testLedgerStoreCanReadWithOrWithoutSharedAppGroup() throws {
        let state = try LedgerStore().read()
        XCTAssertNotNil(state["settings"])
        XCTAssertNotNil(state["transactions"])
    }

    func testSideStoreRewrittenAppGroupIsDiscoveredFromProvisioningProfile() throws {
        let expected = "group.com.yunseok.aibudget.AUCS8XRD4S"
        let profile: [String: Any] = ["Entitlements": [
            "com.apple.security.application-groups": [expected]
        ]]
        let plist = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        var wrapped = Data([0x30, 0x82, 0x01, 0x00])
        wrapped.append(plist)
        wrapped.append(contentsOf: [0x00, 0x00])
        XCTAssertEqual(LedgerStore.provisionedAppGroups(from: wrapped), [expected])
        XCTAssertEqual(
            LedgerStore.appGroupCandidates(profileData: wrapped, configured: "group.com.yunseok.aibudget").first,
            expected
        )
    }

    func testGroqDefaultModelOrder() {
        XCTAssertEqual(AIClient.groqModelOrder(preferred: ""), [
            "openai/gpt-oss-120b", "qwen/qwen3.8-27b", "openai/gpt-oss-20b",
            "groq/compound-mini", "groq/compound"
        ])
    }

    func testGroqPreferredModelMovesToFrontWithoutDuplication() {
        let models = AIClient.groqModelOrder(preferred: "groq/compound-mini")
        XCTAssertEqual(models.first, "groq/compound-mini")
        XCTAssertEqual(models.count, Set(models).count)
        XCTAssertEqual(Set(models), Set(AIClient.groqModels))
    }

    func testGroqFallbackStatusPolicy() {
        for status in [403, 404, 422, 424, 429, 498, 500, 502, 503] {
            XCTAssertTrue(AIClient.shouldTryNextGroqModel(statusCode: status))
        }
        for status in [400, 401, 413] {
            XCTAssertFalse(AIClient.shouldTryNextGroqModel(statusCode: status))
        }
    }
}
