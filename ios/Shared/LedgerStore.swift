import Foundation
import JavaScriptCore
import CryptoKit

enum LedgerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct CoreEngine {
    let context: JSContext
    init() throws {
        guard let context = JSContext(), let url = Bundle.main.url(forResource: "ledger-core", withExtension: "js") else {
            throw LedgerError.message("장부 계산 모듈을 불러올 수 없습니다.")
        }
        let digest: @convention(block) (String) -> String = { text in
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(digest, forKeyedSubscript: "privacyDigest" as NSString)
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        if let exception = context.exception { throw LedgerError.message(exception.toString()) }
        self.context = context
    }
    func call(_ name: String, _ arguments: [Any] = []) throws -> JSValue {
        context.exception = nil
        guard let value = context.objectForKeyedSubscript("LedgerCore")?.invokeMethod(name, withArguments: arguments),
              context.exception == nil else {
            throw LedgerError.message(context.exception?.toString() ?? "계산에 실패했습니다.")
        }
        return value
    }
    static func json(_ object: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }
    static func object(_ json: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw LedgerError.message("장부 데이터가 손상되었습니다.")
        }
        return result
    }
}

struct LedgerStore {
    private var file: URL {
        get throws {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
                  let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw LedgerError.message("장부 저장 공간에 접근할 수 없습니다. 앱 서명과 App Group 설정을 확인해주세요.")
            }
            return folder.appendingPathComponent("ledger-v2.json")
        }
    }
    // Coordinates app, App Intents and Widget extension writes across processes.
    func read() throws -> [String: Any] {
        let engine = try CoreEngine(), url = try file
        var result: Result<[String: Any], Error>?, error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { location in
            result = Result {
                let data = try load(location, engine: engine)
                _ = try engine.call("validate", [data])
                return data
            }
        }
        if let error { throw error }
        guard let result else { throw LedgerError.message("장부 읽기를 완료하지 못했습니다.") }
        return try result.get()
    }
    private func load(_ url: URL, engine: CoreEngine) throws -> [String: Any] {
        if !FileManager.default.fileExists(atPath: url.path) {
            return try engine.call("initial").toDictionary() as! [String: Any]
        }
        // Never replace a corrupt ledger with an empty ledger.
        let existing = try CoreEngine.object(String(contentsOf: url, encoding: .utf8))
        let oldSettings = existing["settings"] as? [String: Any]
        let needsMigration = existing["privacyVersion"] as? Int != 1 || oldSettings?["cardSources"] == nil
        let migrated = try engine.call("migratePrivacy", [existing]).toDictionary() as! [String: Any]
        if needsMigration {
            let protected = Data(try CoreEngine.json(migrated).utf8)
            try protected.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let backup = url.appendingPathExtension("backup")
        if FileManager.default.fileExists(atPath: backup.path) {
            let old = try CoreEngine.object(String(contentsOf: backup, encoding: .utf8))
            let oldSettings = old["settings"] as? [String: Any]
            if old["privacyVersion"] as? Int != 1 || oldSettings?["cardSources"] == nil {
                let sanitized = try engine.call("migratePrivacy", [old]).toDictionary()!
                try Data(CoreEngine.json(sanitized).utf8).write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        return migrated
    }
    @discardableResult
    func mutate(_ operation: String, _ input: [String: Any] = [:]) throws -> [String: Any] {
        let engine = try CoreEngine(), url = try file
        var payload = input
        if payload["now"] == nil { payload["now"] = ISO8601DateFormatter().string(from: Date()) }
        var result: Result<[String: Any], Error>?, error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { location in
            result = Result {
                let state = try load(location, engine: engine)
                let reply = try engine.call("bridge", [CoreEngine.json(state), operation, CoreEngine.json(payload)])
                let output = try CoreEngine.object(reply.toString())
                let data = Data(try CoreEngine.json(output["state"]!).utf8)
                if FileManager.default.fileExists(atPath: location.path) {
                    // One known-good previous revision. A corrupt source fails above before backup replacement.
                    try Data(CoreEngine.json(state).utf8).write(to: location.appendingPathExtension("backup"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                try data.write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return output
            }
        }
        if let error { throw error }
        guard let result else { throw LedgerError.message("저장을 완료하지 못했습니다.") }
        return try result.get()
    }
    func snapshot() throws -> [String: Any] {
        let engine = try CoreEngine(), state = try read()
        let day = try engine.call("dateKey", [ISO8601DateFormatter().string(from: Date())]).toString()!
        return try engine.call("snapshot", [state, day]).toDictionary() as! [String: Any]
    }
}

func won(_ value: Any?) -> String {
    let number = (value as? NSNumber)?.int64Value ?? 0
    return number.formatted(.number.locale(Locale(identifier: "ko_KR"))) + "원"
}
