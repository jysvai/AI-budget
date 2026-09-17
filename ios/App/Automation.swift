import AppIntents
import Foundation
import UserNotifications
import WidgetKit

enum Notices {
    static func show(_ title: String, _ body: String, id: String = UUID().uuidString) async throws {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    static func scheduleSalary(_ settings: [String: Any]) async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<12).map { "salary-\($0)" })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(), current = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        for offset in 0..<12 {
            let month = calendar.date(byAdding: .month, value: offset, to: current)!
            var components = calendar.dateComponents([.year, .month], from: month)
            components.timeZone = calendar.timeZone
            components.day = min(settings["salaryDay"] as? Int ?? 25, calendar.range(of: .day, in: .month, for: month)!.count)
            components.hour = settings["reminderHour"] as? Int ?? 20; components.minute = 0
            guard calendar.date(from: components)! > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "이번 달 월급을 확인해주세요"
            content.body = "앱에서 실제 입금액을 확인하면 예산이 다시 계산됩니다."
            content.userInfo = ["screen": "salary"]
            try await center.add(UNNotificationRequest(identifier: "salary-\(offset)", content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
    }
}

actor AuditRunner {
    static let shared = AuditRunner()
    private var running = false
    func run(type: String? = nil, notify: Bool = true) async throws -> String {
        guard !running else { return "결산을 진행 중입니다." }
        running = true
        defer { running = false; WidgetCenter.shared.reloadAllTimelines() }
        let store = LedgerStore(), engine = try CoreEngine(), state = try store.read()
        let settings = state["settings"] as! [String: Any]
        let now = ISO8601DateFormatter().string(from: Date())
        let today = try engine.call("dateKey", [now]).toString()!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let dayFormatter = DateFormatter(); dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone; dayFormatter.dateFormat = "yyyy-MM-dd"
        var jobs: [[String: String]] = []
        if let type { jobs = [["type": type, "day": today]] }
        else {
            // Catch up recent interrupted runs and closed month/year reports without a second OS automation.
            for offset in (0...7).reversed() {
                if offset == 0 && calendar.component(.hour, from: Date()) < (settings["auditHour"] as? Int ?? 22) { continue }
                let date = calendar.date(byAdding: .day, value: -offset, to: Date())!
                let day = dayFormatter.string(from: date)
                jobs += try engine.call("due", [state, day]).toArray() as? [[String: String]] ?? []
            }
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
            let previousMonthEnd = dayFormatter.string(from: calendar.date(byAdding: .day, value: -1, to: monthStart)!)
            jobs.append(["type": "monthly", "day": previousMonthEnd])
            let year = calendar.component(.year, from: Date()) - 1
            jobs.append(["type": "yearly", "day": "\(year)-12-31"])
        }
        let transactions = state["transactions"] as? [[String: Any]] ?? []
        let firstDay = transactions.compactMap { $0["day"] as? String }.min() ?? today
        var created: [[String: Any]] = [], seen = Set<String>()
        for job in jobs where job["day"]! >= firstDay {
            let result = try store.mutate("report", ["type": job["type"]!, "day": job["day"]!, "now": now])
            guard let report = result["value"] as? [String: Any], let id = report["id"] as? String, seen.insert(id).inserted else { continue }
            created.append(report)
        }
        var failures = 0
        // Save all numeric reports before network. Bound background network work; remaining reports retry on next run.
        let pending = created.filter { $0["source"] as? String == "local" }
            .sorted { ($0["start"] as? String ?? "") > ($1["start"] as? String ?? "") }
        if settings["aiMode"] as? String != "local", settings["consent"] as? Bool == true {
            do {
                let batch = Array(pending.prefix(12))
                let results: [String: [String: Any]]
                if batch.isEmpty { results = [:] }
                else { results = try await AIClient.analyzeBatch(reports: batch, settings: settings) }
                for report in batch {
                    guard let content = results[report["id"] as! String] else { continue }
                    try store.mutate("aiResult", ["id": report["id"]!, "fingerprint": report["fingerprint"]!,
                        "content": content, "source": settings["provider"]!])
                }
            } catch { failures += 1 }
        }
        let message = "\(created.count)개 기간의 숫자 결산을 저장했습니다." + (failures > 0 ? " AI 연결이 지연되어 기기 내 분석을 표시합니다." : "")
        if notify {
            let saved = try store.read()["reports"] as? [[String: Any]] ?? []
            let latest = saved.first { $0["id"] as? String == "daily-" + today }
            let content = latest?["content"] as? [String: Any]
            try await Notices.show("가계부 결산", (content?["summary"] as? String ?? message), id: "audit-" + today)
        }
        return message
    }
}

struct RecordMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "카드 거래 알림 기록"
    static var description = IntentDescription("문자 또는 이메일 자동화의 본문을 가계부에 기록합니다. 승인·취소·환불을 모두 연결하세요.")
    static var openAppWhenRun = false
    @Parameter(title: "알림 본문") var message: String
    @Parameter(title: "카드사 이름", description: "본문에 카드사명이 없을 때 설정 화면과 같은 이름을 넣으세요.") var cardIssuer: String?
    static var parameterSummary: some ParameterSummary { Summary("\(\.$message)을 가계부에 기록") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try LedgerStore().mutate("sms", ["text": message, "sourceName": cardIssuer ?? "",
            "origin": "shortcut", "id": UUID().uuidString])
        WidgetCenter.shared.reloadAllTimelines()
        let text = result["value"] as? String ?? "기록했습니다."
        try await Notices.show("거래 기록", text)
        return .result(value: text)
    }
}

struct RecordWalletTransactionIntent: AppIntent {
    static var title: LocalizedStringResource = "Wallet 거래 기록"
    static var description = IntentDescription("Apple Wallet 거래 자동화가 전달한 승인 금액과 가맹점을 기록합니다.")
    static var openAppWhenRun = false
    @Parameter(title: "금액 (원)") var amount: Int
    @Parameter(title: "가맹점") var merchant: String
    @Parameter(title: "카드사 이름") var cardIssuer: String
    static var parameterSummary: some ParameterSummary { Summary("\(\.$merchant) \(\.$amount)원 기록") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard amount > 0 else { throw LedgerError.message("거래 금액은 0원보다 커야 합니다.") }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd"
        _ = try LedgerStore().mutate("manual", ["id": UUID().uuidString, "kind": "expense", "amount": amount,
            "store": merchant, "category": "미분류", "day": formatter.string(from: Date()),
            "eventType": "approval", "card": cardIssuer, "origin": "wallet"])
        WidgetCenter.shared.reloadAllTimelines()
        let text = merchant + " " + amount.formatted() + "원 승인 기록"
        try await Notices.show("Wallet 거래 기록", text)
        return .result(value: text)
    }
}

struct RecordNoticeImageIntent: AppIntent {
    static var title: LocalizedStringResource = "푸시 화면 OCR 기록"
    static var description = IntentDescription("스크린샷의 카드 알림을 기기에서 읽고, 이미지 원본 없이 거래만 기록합니다.")
    static var openAppWhenRun = false
    @Parameter(title: "푸시 화면") var image: IntentFile
    @Parameter(title: "카드사 이름") var cardIssuer: String
    static var parameterSummary: some ParameterSummary { Summary("\(\.$image)의 \(\.$cardIssuer) 거래 기록") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let recognized = try await NoticeOCR.recognize(image.data)
        let result = try LedgerStore().mutate("sms", ["text": recognized, "sourceName": cardIssuer,
            "origin": "screenshot", "id": UUID().uuidString])
        WidgetCenter.shared.reloadAllTimelines()
        let text = result["value"] as? String ?? "기록했습니다."
        try await Notices.show("푸시 화면 기록", text)
        return .result(value: text)
    }
}

struct RunAuditIntent: AppIntent {
    static var title: LocalizedStringResource = "예약 결산 실행"
    static var description = IntentDescription("오늘의 일간·주간·월간·연간 결산을 확인하고 필요한 보고서를 생성합니다.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: try await AuditRunner.shared.run())
    }
}

struct BudgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunAuditIntent(), phrases: ["\(.applicationName) 결산해줘"], shortTitle: "예약 결산", systemImageName: "chart.bar.xaxis")
    }
}
