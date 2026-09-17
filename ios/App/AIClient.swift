import Foundation
import Security

private struct AIHTTPError: Error {
    let statusCode: Int
}

enum Secrets {
    static func get(_ name: String) -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AIBudget", kSecAttrAccount as String: name,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ name: String, _ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AIBudget", kSecAttrAccount as String: name]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let fields: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if update == errSecItemNotFound {
            guard SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw LedgerError.message("API 키 저장에 실패했습니다.")
            }
        } else if update != errSecSuccess { throw LedgerError.message("API 키 변경에 실패했습니다.") }
    }
}

struct AIClient {
    static let instruction = "한국어 소비 분석가입니다. 입력은 기록된 거래의 집계이며 누락될 수 있습니다. 제공된 숫자만 사용하고 소비 동기나 성격을 단정하지 마세요. status(stable/attention/review), summary(문자열), insights(문자열 배열), actions(문자열 배열)만 가진 JSON을 반환하세요. 연간은 월별 패턴, 월간은 예산, 주간은 반복 경향, 일간은 짧은 관찰을 작성하세요."
    static let groqModels = [
        "openai/gpt-oss-120b",
        "qwen/qwen3.8-27b",
        "openai/gpt-oss-20b",
        "groq/compound-mini",
        "groq/compound"
    ]
    static let strictGroqModels: Set<String> = [
        "openai/gpt-oss-120b", "qwen/qwen3.8-27b", "openai/gpt-oss-20b"
    ]
    static let batchSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["reports"],
        "properties": ["reports": [
            "type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["id", "content"],
                "properties": [
                    "id": ["type": "string"],
                    "content": [
                        "type": "object", "additionalProperties": false,
                        "required": ["status", "summary", "insights", "actions"],
                        "properties": [
                            "status": ["type": "string", "enum": ["stable", "attention", "review"]],
                            "summary": ["type": "string"],
                            "insights": ["type": "array", "items": ["type": "string"]],
                            "actions": ["type": "array", "items": ["type": "string"]]
                        ]
                    ]
                ]
            ]
        ]]
    ]
    static func post(_ url: URL, body: [String: Any], key: String?) async throws -> [String: Any] {
        guard url.scheme == "https" else { throw LedgerError.message("AI 연결에는 HTTPS 주소가 필요합니다.") }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LedgerError.message("AI에 연결하지 못했습니다. 숫자 결산은 저장되었습니다.")
        }
        guard data.count < 100_000 else { throw LedgerError.message("AI 응답이 너무 큽니다.") }
        guard (200..<300).contains(http.statusCode) else { throw AIHTTPError(statusCode: http.statusCode) }
        return try CoreEngine.object(String(decoding: data, as: UTF8.self))
    }
    static func groqModelOrder(preferred: String) -> [String] {
        guard !preferred.isEmpty, groqModels.contains(preferred) else { return groqModels }
        return [preferred] + groqModels.filter { $0 != preferred }
    }
    static func shouldTryNextGroqModel(statusCode: Int) -> Bool {
        [403, 404, 422, 424, 429, 498, 500, 502, 503].contains(statusCode)
    }
    static func validate(_ result: [String: Any]) throws -> [String: Any] {
        guard let status = result["status"] as? String, ["stable", "attention", "review"].contains(status),
              let summary = result["summary"] as? String, !summary.isEmpty, summary.count <= 2000,
              let insights = result["insights"] as? [String], insights.count <= 8, insights.allSatisfy({ $0.count <= 1000 }),
              let actions = result["actions"] as? [String], actions.count <= 5, actions.allSatisfy({ $0.count <= 1000 }) else {
            throw LedgerError.message("AI 응답 형식이 맞지 않아 숫자 결산을 유지합니다.")
        }
        return ["status": status, "summary": summary, "insights": insights, "actions": actions]
    }
    static func analyzeBatch(reports: [[String: Any]], settings: [String: Any]) async throws -> [String: [String: Any]] {
        let payload: [String: Any] = ["reports": reports.map { ["id": $0["id"]!, "stats": $0["stats"]!] }]
        let reply = try await request(payload: payload, settings: settings)
        guard let rows = reply["reports"] as? [[String: Any]], rows.count == reports.count else { throw LedgerError.message("AI 결산 응답 수가 맞지 않습니다.") }
        let expected = Set(reports.compactMap { $0["id"] as? String })
        var results: [String: [String: Any]] = [:]
        for row in rows {
            guard let id = row["id"] as? String, expected.contains(id), results[id] == nil,
                  let content = row["content"] as? [String: Any] else { throw LedgerError.message("AI 결산 응답 식별자 오류") }
            results[id] = try validate(content)
        }
        return results
    }
    private static func request(payload: [String: Any], settings: [String: Any]) async throws -> [String: Any] {
        let instruction = Self.instruction + " 여러 결산을 입력받습니다. 최상위는 reports 배열이고 각 원소는 입력과 동일한 id 및 앞서 지정한 분석 JSON인 content를 포함해야 합니다. 모든 결산에 응답하세요. summary는 2문장 이하, insights는 최대 3개, actions는 최대 2개로 간결하게 작성하세요. budget은 현재 설정된 월간 예산 참고값이며 과거 예산이나 연간 합계가 아닙니다."
        guard settings["consent"] as? Bool == true else { throw LedgerError.message("집계 데이터 전송 동의가 필요합니다.") }
        guard settings["aiMode"] as? String == "personal" else { throw LedgerError.message("개인 API를 연결하면 AI 분석을 사용할 수 있습니다.") }
        let provider = settings["provider"] as? String ?? "groq"
        guard let key = Secrets.get("api-" + provider), !key.isEmpty else { throw LedgerError.message("개인 API 키를 입력해주세요.") }
        let configured = settings["model"] as? String ?? ""
        let text = try CoreEngine.json(payload)
        if provider == "gemini" {
            let model = configured.isEmpty ? "gemini-2.5-flash" : configured
            guard model.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else { throw LedgerError.message("모델 ID 오류") }
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
            var request = URLRequest(url: url, timeoutInterval: 18)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": instruction]]],
                "contents": [["parts": [["text": text]]]],
                "generationConfig": ["responseMimeType": "application/json", "maxOutputTokens": 8192]])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 100_000 else { throw LedgerError.message("개인 AI 호출 실패") }
            let reply = try CoreEngine.object(String(decoding: data, as: UTF8.self))
            guard let candidate = (reply["candidates"] as? [[String: Any]])?.first,
                  let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]],
                  let answer = parts.last?["text"] as? String else { throw LedgerError.message("개인 AI 응답 오류") }
            return try CoreEngine.object(answer)
        }
        let endpoints = ["groq": "https://api.groq.com/openai/v1/chat/completions", "openrouter": "https://openrouter.ai/api/v1/chat/completions"]
        guard let endpoint = endpoints[provider] else { throw LedgerError.message("지원하지 않는 공급자") }
        let model = configured.isEmpty ? (provider == "groq" ? "openai/gpt-oss-120b" : "openrouter/free") : configured
        if provider == "groq" {
            guard configured.isEmpty || Self.groqModels.contains(configured) else { throw LedgerError.message("지원하지 않는 Groq 모델입니다.") }
            return try await requestGroq(
                endpoint: URL(string: endpoint)!, key: key, preferred: configured,
                instruction: instruction, text: text,
                expectedIDs: Set((payload["reports"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }))
        }
        var body: [String: Any] = ["model": model,
            "messages": [["role": "system", "content": instruction], ["role": "user", "content": text]],
            "max_tokens": 2500]
        body["response_format"] = ["type": "json_object"]
        let reply = try await post(URL(string: endpoint)!, body: body, key: key)
        return try answerObject(reply)
    }
    private static func requestGroq(endpoint: URL, key: String, preferred: String,
                                    instruction: String, text: String,
                                    expectedIDs: Set<String>) async throws -> [String: Any] {
        let models = groqModelOrder(preferred: preferred)
        for (index, model) in models.enumerated() {
            var body: [String: Any] = [
                "model": model,
                "messages": [["role": "system", "content": instruction], ["role": "user", "content": text]],
                "max_tokens": 2500
            ]
            if strictGroqModels.contains(model) {
                body["reasoning_effort"] = "low"
                body["response_format"] = ["type": "json_schema", "json_schema": [
                    "name": "budget_reports", "strict": true, "schema": Self.batchSchema]]
            } else {
                body["response_format"] = ["type": "json_object"]
                // Compound enables external tools by default. Keep private aggregates out of them.
                body["compound_custom"] = ["tools": ["enabled_tools": [String]()]]
            }
            do {
                let reply = try await post(endpoint, body: body, key: key)
                let answer = try answerObject(reply)
                guard validBatchEnvelope(answer, expectedIDs: expectedIDs) else {
                    throw LedgerError.message("Groq 모델 응답 형식 오류")
                }
                UserDefaults.standard.set(model, forKey: "lastGroqModel")
                return answer
            } catch let error as AIHTTPError {
                if error.statusCode == 401 { throw LedgerError.message("Groq API 키를 확인해주세요.") }
                let compoundConfigurationRejected = error.statusCode == 400 && model.hasPrefix("groq/compound")
                if !shouldTryNextGroqModel(statusCode: error.statusCode) && !compoundConfigurationRejected {
                    throw LedgerError.message("Groq 요청 오류(HTTP \(error.statusCode)). 숫자 결산은 저장되어 있습니다.")
                }
                if index == models.count - 1 { break }
            } catch is URLError {
                throw LedgerError.message("네트워크 연결을 확인해주세요. 숫자 결산은 저장되어 있습니다.")
            } catch {
                if index == models.count - 1 { break }
            }
        }
        throw LedgerError.message("사용 가능한 Groq 분석 모델의 한도 또는 가용성을 확인해주세요. 숫자 결산은 저장되어 있습니다.")
    }
    private static func validBatchEnvelope(_ reply: [String: Any], expectedIDs: Set<String>) -> Bool {
        guard let rows = reply["reports"] as? [[String: Any]], rows.count == expectedIDs.count else { return false }
        var found = Set<String>()
        for row in rows {
            guard let id = row["id"] as? String, expectedIDs.contains(id), found.insert(id).inserted,
                  let content = row["content"] as? [String: Any], (try? validate(content)) != nil else { return false }
        }
        return found == expectedIDs
    }
    private static func answerObject(_ reply: [String: Any]) throws -> [String: Any] {
        guard let choice = (reply["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any], let content = message["content"] as? String else {
            throw LedgerError.message("개인 AI 응답 오류")
        }
        return try CoreEngine.object(content)
    }
}
