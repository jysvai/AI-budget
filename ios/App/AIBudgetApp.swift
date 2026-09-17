import SwiftUI
import WidgetKit
import UserNotifications

@MainActor final class BudgetModel: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var snapshot: [String: Any] = [:]
    @Published var message: String?
    @Published var sharedStorageAvailable = LedgerStore.sharedStorageAvailable
    var settings: [String: Any] { state["settings"] as? [String: Any] ?? [:] }

    func refresh() {
        do {
            state = try LedgerStore().read()
            snapshot = try LedgerStore().snapshot()
            sharedStorageAvailable = LedgerStore.sharedStorageAvailable
        } catch { message = error.localizedDescription }
    }

    @discardableResult func save(_ operation: String, _ input: [String: Any]) -> Bool {
        do {
            try LedgerStore().mutate(operation, input)
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

@main struct AIBudgetApp: App {
    @StateObject private var model = BudgetModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    model.refresh()
                    #if DEBUG
                    DemoData.installIfRequested(into: model)
                    #endif
                    if ProcessInfo.processInfo.environment["MOA_SCREENSHOT_DEMO"] != "1" {
                        await Notices.requestAuthorizationIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    model.refresh()
                    Task {
                        do {
                            try await Notices.scheduleSalary(model.settings)
                            if model.settings["setupDone"] as? Bool == true {
                                _ = try await AuditRunner.shared.run(notify: false)
                                model.refresh()
                            }
                        } catch { model.message = error.localizedDescription }
                    }
                }
                .alert("모아 안내", isPresented: Binding(
                    get: { model.message != nil },
                    set: { if !$0 { model.message = nil } }
                )) {
                    Button("확인") { model.message = nil }
                } message: { Text(model.message ?? "") }
        }
    }
}

struct RootView: View {
    @State private var selection = 0
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { DashboardView() }
                .tabItem { Label("홈", systemImage: "house.fill") }
                .tag(0)
            NavigationStack { TransactionsView() }
                .tabItem { Label("거래", systemImage: "arrow.left.arrow.right") }
                .tag(1)
            NavigationStack { ReportsView() }
                .tabItem { Label("결산", systemImage: "sparkles") }
                .tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("설정", systemImage: "slider.horizontal.3") }
                .tag(3)
        }
        .tint(MoaTheme.teal)
        .onOpenURL { url in
            switch url.host {
            case "transactions": selection = 1
            case "reports": selection = 2
            case "settings": selection = 3
            default: selection = 0
            }
        }
    }
}

#if DEBUG
@MainActor enum DemoData {
    static func installIfRequested(into model: BudgetModel) {
        guard ProcessInfo.processInfo.environment["MOA_SCREENSHOT_DEMO"] == "1" else { return }
        let existing = model.state["transactions"] as? [[String: Any]] ?? []
        guard !existing.contains(where: { $0["id"] as? String == "demo-coffee" }) else { return }
        var settings = model.settings
        settings["expectedSalary"] = 3_800_000
        settings["savingsGoal"] = 1_200_000
        settings["salaryDay"] = 25
        settings["reminderHour"] = 20
        settings["auditHour"] = 22
        settings["weekEnd"] = 0
        settings["setupDone"] = true
        settings["smsGuideDone"] = true
        settings["auditGuideDone"] = true
        settings["plans"] = [
            ["id": "demo-rent", "name": "월세", "amount": 650_000, "merchant": "", "day": 1],
            ["id": "demo-phone", "name": "통신비", "amount": 72_000, "merchant": "", "day": 12]
        ]
        _ = model.save("settings", ["settings": settings])
        _ = model.save("salary", ["amount": 3_800_000])
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        let rows: [[String: Any]] = [
            ["id": "demo-market", "kind": "expense", "eventType": "approval", "amount": 84_300, "store": "동네 마트", "category": "식비", "day": day, "planID": "", "originalID": ""],
            ["id": "demo-coffee", "kind": "expense", "eventType": "approval", "amount": 5_500, "store": "모닝 커피", "category": "카페", "day": day, "planID": "", "originalID": ""],
            ["id": "demo-transit", "kind": "expense", "eventType": "approval", "amount": 21_000, "store": "교통카드", "category": "교통", "day": day, "planID": "", "originalID": ""]
        ]
        rows.forEach { _ = model.save("manual", $0) }
    }
}
#endif

struct DashboardView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var salary = ""
    @State private var add = false
    @State private var importNotice = false

    private var budget: Double { (model.snapshot["budget"] as? NSNumber)?.doubleValue ?? 0 }
    private var spent: Double { (model.snapshot["variableSpent"] as? NSNumber)?.doubleValue ?? 0 }
    private var progress: Double { budget > 0 ? min(max(spent / budget, 0), 1) : 0 }
    private var recent: [[String: Any]] {
        Array((model.state["transactions"] as? [[String: Any]] ?? [])
            .sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") }
            .prefix(4))
    }

    var body: some View {
        MoaPage {
            if model.settings["setupDone"] as? Bool != true {
                NavigationLink { QuickSetupView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "wand.and.stars").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("3분이면 준비 끝").font(.headline)
                            Text("월급과 결산 시간만 먼저 맞춰보세요").font(.caption)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(MoaTheme.coral.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.snapshot["month"] as? String ?? "이번 달")
                            .font(.subheadline.bold()).foregroundStyle(.white.opacity(0.78))
                        Text("남은 생활비").font(.headline).foregroundStyle(.white)
                    }
                    Spacer()
                    MoaStatusPill(
                        text: model.snapshot["salaryConfirmed"] as? Bool == true ? "월급 반영됨" : "예상 월급 기준",
                        systemImage: model.snapshot["salaryConfirmed"] as? Bool == true ? "checkmark" : "clock",
                        color: .white
                    )
                }
                Text(won(model.snapshot["remaining"]))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.65)
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress).tint(.white)
                    HStack {
                        Text("생활비의 \(Int(progress * 100))% 사용")
                        Spacer()
                        Text("하루 \(won(model.snapshot["recommendedDaily"]))")
                    }
                    .font(.caption.bold()).foregroundStyle(.white.opacity(0.82))
                }
            }
            .padding(22)
            .background(MoaTheme.hero, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: MoaTheme.teal.opacity(0.25), radius: 18, y: 10)

            HStack(spacing: 12) {
                DashboardAction(title: "직접 기록", systemImage: "plus", tint: MoaTheme.teal) { add = true }
                DashboardAction(title: "화면 가져오기", systemImage: "text.viewfinder", tint: MoaTheme.coral) { importNotice = true }
            }

            MoaSectionTitle(title: "이번 달 한눈에", subtitle: "취소와 환불이 반영된 금액입니다")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MoaMetric(title: "순지출", value: won(model.snapshot["spent"]), systemImage: "creditcard.fill", tint: MoaTheme.coral)
                MoaMetric(title: "실제 수입", value: won(model.snapshot["actualIncome"]), systemImage: "arrow.down.circle.fill")
                MoaMetric(title: "고정비 예약", value: won(model.snapshot["reserved"]), systemImage: "calendar.badge.clock", tint: .indigo)
                MoaMetric(title: "검토 필요", value: "\(model.snapshot["pendingCount"] as? Int ?? 0)건", systemImage: "tray.full.fill", tint: .orange)
            }

            if model.snapshot["salaryConfirmed"] as? Bool != true {
                MoaCard {
                    MoaSectionTitle(title: "월급 확인", subtitle: "실제 입금액을 반영하면 예산이 더 정확해져요")
                    TextField("실제 입금액", text: $salary)
                        .keyboardType(.numberPad)
                        .moaField()
                    HStack {
                        Button("예상 월급 사용") {
                            _ = model.save("salary", ["amount": model.settings["expectedSalary"] ?? 0])
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("반영하기") {
                            guard let amount = Int64(salary) else { model.message = "입금액을 숫자로 입력해주세요."; return }
                            if model.save("salary", ["amount": amount]) { salary = "" }
                        }
                        .buttonStyle(.borderedProminent).tint(MoaTheme.teal)
                    }
                }
            }

            if !recent.isEmpty {
                MoaSectionTitle(title: "최근 거래")
                MoaCard(padding: 4) {
                    ForEach(recent.indices, id: \.self) { index in
                        TransactionRow(row: recent[index])
                        if index < recent.count - 1 { Divider().padding(.leading, 58) }
                    }
                }
            }

            if !model.sharedStorageAvailable {
                MoaCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "iphone.gen3").foregroundStyle(MoaTheme.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("앱 전용 저장 모드").font(.headline)
                            Text("장부와 AI 분석은 정상 작동합니다. 위젯 연결 상태는 설정의 자동화 센터에서 확인할 수 있어요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("모아")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $add) { NavigationStack { EntryView() } }
        .sheet(isPresented: $importNotice) { NavigationStack { NoticeImportView() } }
    }
}

struct DashboardAction: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(tint)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct TransactionsView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var add = false
    @State private var importNotice = false
    @State private var review: PendingSelection?
    private var rows: [[String: Any]] {
        (model.state["transactions"] as? [[String: Any]] ?? [])
            .sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") }
    }

    var body: some View {
        List {
            let pending = model.state["pending"] as? [[String: Any]] ?? []
            if !pending.isEmpty {
                Section {
                    ForEach(pending.indices, id: \.self) { index in
                        Button { review = PendingSelection(id: pending[index]["id"] as! String) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles.rectangle.stack.fill").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pending[index]["reason"] as? String ?? "확인 필요").font(.headline)
                                    Text(pending[index]["text"] as? String ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                } header: { Text("검토함 · 아직 합계에 반영되지 않음") }
            }
            Section {
                if rows.isEmpty {
                    ContentUnavailableView("아직 거래가 없어요", systemImage: "tray", description: Text("오른쪽 위 + 버튼으로 첫 거래를 기록해보세요."))
                } else {
                    ForEach(rows.indices, id: \.self) { index in
                        TransactionRow(row: rows[index])
                            .swipeActions {
                                if rows[index]["origin"] as? String == "manual" {
                                    Button("삭제", role: .destructive) { _ = model.save("deleteTransaction", ["id": rows[index]["id"]!]) }
                                }
                            }
                    }
                }
            } header: { Text("전체 거래") }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MoaTheme.canvas)
        .navigationTitle("거래")
        .toolbar {
            Menu {
                Button("직접 기록", systemImage: "square.and.pencil") { add = true }
                Button("푸시 화면 가져오기", systemImage: "text.viewfinder") { importNotice = true }
            } label: { Label("추가", systemImage: "plus.circle.fill") }
        }
        .sheet(isPresented: $add) { NavigationStack { EntryView() } }
        .sheet(isPresented: $importNotice) { NavigationStack { NoticeImportView() } }
        .sheet(item: $review) { selection in NavigationStack { EntryView(pendingID: selection.id) } }
    }
}

struct TransactionRow: View {
    let row: [String: Any]
    private var type: String { row["eventType"] as? String ?? row["kind"] as? String ?? "expense" }
    private var isReturn: Bool { type == "cancellation" || type == "refund" }
    private var isIncome: Bool { type == "income" || row["kind"] as? String == "income" }
    private var title: String { (row["store"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (isIncome ? "수입" : "지출") }
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: isIncome ? "arrow.down" : isReturn ? "arrow.uturn.backward" : "creditcard")
                .font(.subheadline.bold())
                .foregroundStyle(isIncome ? MoaTheme.teal : isReturn ? .orange : MoaTheme.coral)
                .frame(width: 40, height: 40)
                .background((isIncome ? MoaTheme.teal : isReturn ? Color.orange : MoaTheme.coral).opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold()).lineLimit(1)
                Text("\(row["day"] as? String ?? "") · \(row["category"] as? String ?? "기타")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text((isIncome || isReturn ? "+" : "−") + won(row["amount"]))
                .font(.subheadline.bold())
                .foregroundStyle(isIncome ? MoaTheme.teal : isReturn ? .orange : .primary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }
}

struct PendingSelection: Identifiable { let id: String }

struct EntryView: View {
    @EnvironmentObject var model: BudgetModel
    @Environment(\.dismiss) var dismiss
    var pendingID: String? = nil
    @State private var kind = "expense"
    @State private var amount = ""
    @State private var store = ""
    @State private var category = "기타"
    @State private var planID = ""
    @State private var originalID = ""
    @State private var date = Date()

    var body: some View {
        Form {
            if pendingID != nil {
                Section { Label("검토한 알림을 거래로 확정합니다.", systemImage: "checkmark.seal") }
            }
            Section("거래 정보") {
                Picker("종류", selection: $kind) {
                    Text("지출").tag("expense"); Text("수입").tag("income")
                    Text("취소").tag("cancellation"); Text("환불").tag("refund")
                }.pickerStyle(.segmented)
                TextField("금액", text: $amount).keyboardType(.numberPad)
                TextField("내용 또는 가맹점", text: $store)
                Picker("분류", selection: $category) {
                    ForEach(["기타", "식비", "카페", "쇼핑", "교통", "주거", "의료", "문화", "고정비", "추가수입"], id: \.self) { Text($0) }
                }
                DatePicker("거래일", selection: $date, displayedComponents: .date)
            }
            if kind == "cancellation" || kind == "refund" {
                Section("원거래") {
                    let originals = (model.state["transactions"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "expense" }
                    Picker("연결할 거래", selection: $originalID) {
                        Text("모름 / 연결하지 않음").tag("")
                        ForEach(originals.indices, id: \.self) { index in
                            Text("\(originals[index]["day"] as? String ?? "") \(originals[index]["store"] as? String ?? "") \(won(originals[index]["amount"]))")
                                .tag(originals[index]["id"] as? String ?? "")
                        }
                    }
                }
            }
            let plans = model.settings["plans"] as? [[String: Any]] ?? []
            if !plans.isEmpty {
                Section("고정비 연결") {
                    Picker("예약 항목", selection: $planID) {
                        Text("해당 없음").tag("")
                        ForEach(plans.indices, id: \.self) { index in
                            Text(plans[index]["name"] as? String ?? "").tag(plans[index]["id"] as? String ?? "")
                        }
                    }
                }
            }
            Section {
                Button("거래 저장") { save() }.frame(maxWidth: .infinity).font(.headline)
            }
        }
        .navigationTitle("빠른 기록")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
    }

    private func save() {
        guard let value = Int64(amount), value > 0 else { model.message = "0보다 큰 금액을 입력해주세요."; return }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd"
        var data: [String: Any] = [
            "id": UUID().uuidString, "kind": kind == "cancellation" ? "refund" : kind,
            "eventType": kind, "amount": value, "store": store, "category": category,
            "day": formatter.string(from: date), "planID": planID, "originalID": originalID
        ]
        if let pendingID { data["pendingID"] = pendingID }
        if model.save("manual", data) { dismiss() }
    }
}

struct ReportsView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var selected = "daily"
    @State private var running = false
    private let names = ["daily": "야간", "weekly": "주간", "monthly": "월말", "yearly": "연간"]
    private var reports: [[String: Any]] {
        (model.state["reports"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == selected }
            .sorted { ($0["start"] as? String ?? "") > ($1["start"] as? String ?? "") }
    }

    var body: some View {
        MoaPage {
            Picker("결산 주기", selection: $selected) {
                ForEach(["daily", "weekly", "monthly", "yearly"], id: \.self) { Text(names[$0]!).tag($0) }
            }
            .pickerStyle(.segmented)
            MoaCard {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(MoaTheme.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("지금까지의 소비를 정리할까요?").font(.headline)
                        Text("숫자 결산은 기기에서 먼저 저장되고, 선택한 경우에만 AI 분석을 덧붙입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                MoaPrimaryButton(title: running ? "분석 중…" : "현재 기간 결산 만들기", systemImage: "wand.and.stars", disabled: running) {
                    running = true
                    Task {
                        do { model.message = try await AuditRunner.shared.run(type: selected) }
                        catch { model.message = error.localizedDescription }
                        model.refresh(); running = false
                    }
                }
            }
            if reports.isEmpty {
                MoaCard {
                    ContentUnavailableView("아직 \(names[selected] ?? "") 결산이 없어요", systemImage: "doc.text.magnifyingglass", description: Text("위 버튼을 눌러 첫 결산을 만들어보세요."))
                }
            } else {
                ForEach(reports.indices, id: \.self) { index in ReportCard(report: reports[index]) }
            }
        }
        .navigationTitle("결산")
    }
}

struct ReportCard: View {
    let report: [String: Any]
    private var content: [String: Any] { report["content"] as? [String: Any] ?? [:] }
    var body: some View {
        MoaCard {
            HStack {
                Text(report["start"] as? String ?? "").font(.subheadline.bold())
                Spacer()
                MoaStatusPill(
                    text: report["source"] as? String == "local" ? "기기 분석" : "AI 분석",
                    systemImage: report["source"] as? String == "local" ? "iphone" : "sparkles"
                )
            }
            Text(content["summary"] as? String ?? "").font(.body)
            ForEach(content["insights"] as? [String] ?? [], id: \.self) { insight in
                Label(insight, systemImage: "chart.line.uptrend.xyaxis").font(.subheadline)
            }
            ForEach(content["actions"] as? [String] ?? [], id: \.self) { action in
                Label(action, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(MoaTheme.teal)
            }
        }
    }
}
