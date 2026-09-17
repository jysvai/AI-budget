import SwiftUI
import WidgetKit
import UserNotifications

@MainActor final class BudgetModel: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var snapshot: [String: Any] = [:]
    @Published var message: String?
    var settings: [String: Any] { state["settings"] as? [String: Any] ?? [:] }
    func refresh() {
        do { state = try LedgerStore().read(); snapshot = try LedgerStore().snapshot() }
        catch { message = error.localizedDescription }
    }
    @discardableResult func save(_ operation: String, _ input: [String: Any]) -> Bool {
        do { try LedgerStore().mutate(operation, input); refresh(); WidgetCenter.shared.reloadAllTimelines(); return true }
        catch { message = error.localizedDescription; return false }
    }
}

@main struct AIBudgetApp: App {
    @StateObject private var model = BudgetModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .task { model.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
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
                }
                .alert("가계부 안내", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("확인") { model.message = nil }
                } message: { Text(model.message ?? "") }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: BudgetModel
    var body: some View {
        TabView {
            NavigationStack { DashboardView() }.tabItem { Label("현황", systemImage: "chart.pie.fill") }
            NavigationStack { TransactionsView() }.tabItem { Label("거래", systemImage: "list.bullet.rectangle") }
            NavigationStack { ReportsView() }.tabItem { Label("결산", systemImage: "chart.bar.doc.horizontal") }
            NavigationStack { SettingsView() }.tabItem { Label("설정", systemImage: "gearshape") }
        }.tint(.teal)
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var salary = ""
    @State private var add = false
    var body: some View {
        List {
            if model.settings["setupDone"] as? Bool != true {
                Section { NavigationLink("처음 설정하고 자동 기록 시작하기") { SettingsView() } }
            }
            Section("\(model.snapshot["month"] as? String ?? "") · 생활비") {
                Text(won(model.snapshot["remaining"])).font(.largeTitle.bold()).foregroundStyle(.teal)
                LabeledContent("남은 기간 하루 권장액", value: won(model.snapshot["recommendedDaily"]))
                LabeledContent("생활비 예산", value: won(model.snapshot["budget"]))
                LabeledContent("변동지출", value: won(model.snapshot["variableSpent"]))
            }
            Section("수입과 지출") {
                LabeledContent("기록된 실제 수입", value: won(model.snapshot["actualIncome"]))
                LabeledContent("예산 기준 수입", value: won(model.snapshot["incomeForBudget"]))
                if model.snapshot["salaryConfirmed"] as? Bool != true { Text("월급 미확인: 예상 월급으로 예산을 계산하고 있습니다.").font(.caption).foregroundStyle(.secondary) }
                LabeledContent("승인·지출 합계", value: won(model.snapshot["grossSpent"]))
                LabeledContent("취소 합계", value: won(model.snapshot["cancellationTotal"]))
                LabeledContent("환불 합계", value: won(model.snapshot["refundTotal"]))
                LabeledContent("취소·환불 반영 순지출", value: won(model.snapshot["spent"]))
                if let rate = model.snapshot["spendingRate"] as? Double { LabeledContent("실제 수입 대비 지출", value: rate.formatted(.percent.precision(.fractionLength(1)))) }
                else { Text("실제 수입을 기록하면 지출 비율을 표시합니다.").font(.caption) }
                LabeledContent("고정비 예약액", value: won(model.snapshot["reserved"]))
                Text("예약액은 예산에서 확보한 금액입니다. 실제 납부 기록과는 구분됩니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("이번 달 월급 확인") {
                TextField("실제 입금액 (원)", text: $salary).keyboardType(.numberPad)
                Button("월급 반영") { if let amount = Int64(salary) { model.save("salary", ["amount": amount]) } else { model.message = "입금액을 입력해주세요." } }
                Button("설정한 예상 월급으로 확인") { model.save("salary", ["amount": model.settings["expectedSalary"] ?? 0]) }
            }
            Section { Button("수입·지출 빠른 입력") { add = true } }
        }.navigationTitle("모아 가계부")
            .sheet(isPresented: $add) { NavigationStack { EntryView() } }
    }
}

struct TransactionsView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var add = false
    @State private var importNotice = false
    @State private var review: PendingSelection?
    var rows: [[String: Any]] { (model.state["transactions"] as? [[String: Any]] ?? []).sorted { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") } }
    var body: some View {
        List {
            let pending = model.state["pending"] as? [[String: Any]] ?? []
            if !pending.isEmpty {
                Section("검토함 · 아직 지출 합계에 미반영") {
                    ForEach(pending.indices, id: \.self) { i in
                        Button { review = PendingSelection(id: pending[i]["id"] as! String) } label: {
                            VStack(alignment: .leading) {
                                Text(pending[i]["reason"] as? String ?? "확인 필요")
                                Text(pending[i]["text"] as? String ?? "").font(.caption).lineLimit(3)
                            }
                        }
                    }
                }
            }
            Section("거래 내역") {
                ForEach(rows.indices, id: \.self) { i in
                    let row = rows[i]
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row["store"] as? String ?? "")
                            let type = row["eventType"] as? String ?? row["kind"] as? String ?? "expense"
                            Text(type == "cancellation" ? "취소" : type == "refund" ? "환불" : type == "income" ? "수입" : "승인·지출")
                                .font(.caption.bold()).foregroundStyle(type == "cancellation" || type == "refund" ? .orange : .secondary)
                            if let original = row["originalID"] as? String {
                                let parent = rows.first { $0["id"] as? String == original }
                                Text("원거래 \(parent?["day"] as? String ?? "") · \(won(parent?["amount"]))\(row["partial"] as? Bool == true ? " · 부분 처리" : "")").font(.caption2)
                            }
                            Text("\(row["day"] as? String ?? "") · \(row["category"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((row["kind"] as? String == "expense" ? "−" : "+") + won(row["amount"]))
                    }.swipeActions {
                        if row["origin"] as? String == "manual" {
                            Button("삭제", role: .destructive) { model.save("deleteTransaction", ["id": row["id"]!]) }
                        }
                    }
                }
            }
        }.navigationTitle("거래 내역")
            .toolbar {
                Menu {
                    Button("수동 입력", systemImage: "square.and.pencil") { add = true }
                    Button("푸시 화면 가져오기", systemImage: "text.viewfinder") { importNotice = true }
                } label: { Label("추가", systemImage: "plus") }
            }
            .sheet(isPresented: $add) { NavigationStack { EntryView() } }
            .sheet(isPresented: $importNotice) { NavigationStack { NoticeImportView() } }
            .sheet(item: $review) { selection in NavigationStack { EntryView(pendingID: selection.id) } }
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
            if pendingID != nil { Text("문자를 확인해 기록하면 검토함에서 처리 완료됩니다. 이미 수동으로 기록한 거래와 중복되지 않는지 확인해주세요.") }
            Picker("종류", selection: $kind) { Text("지출").tag("expense"); Text("수입").tag("income"); Text("취소").tag("cancellation"); Text("환불").tag("refund") }
            if kind == "cancellation" || kind == "refund" {
                let originals = (model.state["transactions"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "expense" }
                Picker("원거래 연결", selection: $originalID) {
                    Text("원거래 없음 / 모름").tag("")
                    ForEach(originals.indices, id: \.self) { i in
                        Text("\(originals[i]["day"] as? String ?? "") \(originals[i]["store"] as? String ?? "") \(won(originals[i]["amount"]))").tag(originals[i]["id"] as? String ?? "")
                    }
                }
            }
            TextField("금액 (원)", text: $amount).keyboardType(.numberPad)
            TextField("내용 / 가맹점", text: $store)
            Picker("분류", selection: $category) {
                ForEach(["기타", "식비", "카페", "쇼핑", "교통", "주거", "의료", "문화", "고정비", "추가수입"], id: \.self) { Text($0) }
            }
            DatePicker("거래일", selection: $date, displayedComponents: .date)
            let plans = model.settings["plans"] as? [[String: Any]] ?? []
            Picker("예약 고정비 연결", selection: $planID) {
                Text("해당 없음").tag("")
                ForEach(plans.indices, id: \.self) { i in Text(plans[i]["name"] as? String ?? "").tag(plans[i]["id"] as? String ?? "") }
            }
            Button("저장") {
                guard let value = Int64(amount) else { model.message = "금액을 입력해주세요."; return }
                let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Seoul"); formatter.dateFormat = "yyyy-MM-dd"
                var data: [String: Any] = ["id": UUID().uuidString, "kind": kind == "cancellation" ? "refund" : kind, "eventType": kind,
                    "amount": value, "store": store, "category": category, "day": formatter.string(from: date), "planID": planID, "originalID": originalID]
                if let pendingID { data["pendingID"] = pendingID }
                if model.save("manual", data) { dismiss() }
            }
        }.navigationTitle("빠른 입력").toolbar { Button("닫기") { dismiss() } }
    }
}

struct ReportsView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var selected = "daily"
    @State private var running = false
    let names = ["daily": "야간", "weekly": "주간", "monthly": "월간", "yearly": "연간"]
    var body: some View {
        List {
            Section {
                Picker("결산 주기", selection: $selected) { ForEach(["daily", "weekly", "monthly", "yearly"], id: \.self) { Text(names[$0]!).tag($0) } }.pickerStyle(.segmented)
                Button(running ? "분석 중…" : "현재 기간 결산 생성") {
                    running = true
                    Task {
                        do { model.message = try await AuditRunner.shared.run(type: selected) } catch { model.message = error.localizedDescription }
                        model.refresh(); running = false
                    }
                }.disabled(running)
                Text("진행 중인 기간은 현재 기록까지의 잠정 결산입니다. 야간 결산 이후 거래는 다음 실행 시 반영됩니다.").font(.caption).foregroundStyle(.secondary)
            }
            let reports = (model.state["reports"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == selected }
                .sorted { ($0["start"] as? String ?? "") > ($1["start"] as? String ?? "") }
            ForEach(reports.indices, id: \.self) { i in
                let report = reports[i], content = report["content"] as? [String: Any] ?? [:]
                Section("\(report["start"] as? String ?? "") · \(report["source"] as? String == "local" ? "기기 내 분석" : "AI 분석")") {
                    Text(content["summary"] as? String ?? "")
                    ForEach(content["insights"] as? [String] ?? [], id: \.self) { Text($0).font(.subheadline) }
                    ForEach(content["actions"] as? [String] ?? [], id: \.self) { Text($0).foregroundStyle(.teal) }
                }
            }
        }.navigationTitle("소비 패턴 결산")
    }
}
