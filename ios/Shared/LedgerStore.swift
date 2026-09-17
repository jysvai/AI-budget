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
    private static let resolvedGroupIdentifier: String? = {
        let files = FileManager.default
        for identifier in appGroupCandidates() {
            if files.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil {
                return identifier
            }
        }
        return nil
    }()

    static var sharedStorageAvailable: Bool {
        resolvedGroupIdentifier != nil
    }

    static var sharedStorageDescription: String {
        sharedStorageAvailable ? "앱과 위젯 연결됨" : "앱 전용 저장 모드"
    }

    static func appGroupCandidates(profileData: Data? = nil, configured: String? = nil) -> [String] {
        let configured = configured ?? Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        let data = profileData ?? Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        var groups = data.flatMap(provisionedAppGroups) ?? []
        if let configured, !configured.isEmpty {
            groups.sort {
                let left = $0 == configured ? 0 : ($0.hasPrefix(configured + ".") ? 1 : 2)
                let right = $1 == configured ? 0 : ($1.hasPrefix(configured + ".") ? 1 : 2)
                return left < right
            }
            groups.append(configured)
        }
        var seen = Set<String>()
        return groups.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func provisionedAppGroups(from data: Data) -> [String]? {
        let xmlStart = Data("<?xml".utf8)
        let plistStart = Data("<plist".utf8)
        let plistEnd = Data("</plist>".utf8)
        guard let start = data.range(of: xmlStart)?.lowerBound ?? data.range(of: plistStart)?.lowerBound,
              let end = data.range(of: plistEnd, options: .backwards)?.upperBound,
              start < end,
              let object = try? PropertyListSerialization.propertyList(from: data.subdata(in: start..<end), options: [], format: nil),
              let profile = object as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["com.apple.security.application-groups"] as? [String]
    }
    private var file: URL {
        get throws {
            let local = try localFile()
            guard let group = Self.resolvedGroupIdentifier,
                  let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                return local
            }
            let shared = folder.appendingPathComponent("ledger-v2.json")
            try migrateLocalLedgerIfNeeded(from: local, to: shared)
            return shared
        }
    }
    private func localFile() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LedgerError.message("앱 자체 저장 공간을 준비하지 못했습니다.")
        }
        let folder = base.appendingPathComponent("MoaBudget", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ledger-v2.json")
    }
    private func migrateLocalLedgerIfNeeded(from local: URL, to shared: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: shared.path), files.fileExists(atPath: local.path) else { return }
        do { try files.copyItem(at: local, to: shared) }
        catch {
            if files.fileExists(atPath: shared.path) { return }
            throw error
        }
        let localBackup = local.appendingPathExtension("backup")
        let sharedBackup = shared.appendingPathExtension("backup")
        if files.fileExists(atPath: localBackup.path), !files.fileExists(atPath: sharedBackup.path) {
            try? files.copyItem(at: localBackup, to: sharedBackup)
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
