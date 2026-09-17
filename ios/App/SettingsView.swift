import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var expected = ""
    @State private var savings = ""
    @State private var salaryDay = 25
    @State private var reminderHour = 20
    @State private var auditHour = 22
    @State private var weekEnd = 0
    @State private var mode = "local"
    @State private var provider = "groq"
    @State private var modelID = ""
    @State private var key = ""
    @State private var consent = false
    @State private var showPlan = false
    @State private var notificationState = "확인 전"
    var body: some View {
        Form {
            Section("1 · 내 예산") {
                TextField("예상 월급 (원)", text: $expected).keyboardType(.numberPad)
                TextField("목표 저축액 (원)", text: $savings).keyboardType(.numberPad)
                Stepper("월급 확인일: \(salaryDay)일", value: $salaryDay, in: 1...31)
                Text("선택일이 없는 달에는 말일에 안내합니다. 장부는 한국 시간의 달력 월 기준입니다.").font(.caption)
                Stepper("월급 알림: \(reminderHour)시", value: $reminderHour, in: 0...23)
                Stepper("야간 결산: \(auditHour)시", value: $auditHour, in: 0...23)
                Text("결산 시간을 바꾸면 단축어 시간 자동화도 같은 시간으로 변경해주세요.").font(.caption).foregroundStyle(.secondary)
                Picker("주간 마감 요일", selection: $weekEnd) {
                    ForEach(0..<7) { Text(["일", "월", "화", "수", "목", "금", "토"][$0] + "요일").tag($0) }
                }
            }
            Section("2 · 고정비와 구독") {
                let plans = model.settings["plans"] as? [[String: Any]] ?? []
                ForEach(plans.indices, id: \.self) { i in
                    LabeledContent(plans[i]["name"] as? String ?? "", value: won(plans[i]["amount"]))
                }
                Button("고정비 추가 / 변경") { showPlan = true }
                Text("고정비는 예산에서 미리 확보합니다. 실제 지출은 SMS 또는 수동 기록으로 반영합니다.").font(.caption)
            }
            Section("3 · AI 분석") {
                Picker("분석 방식", selection: $mode) {
                    Text("개인 API").tag("personal"); Text("기기 내 숫자 결산").tag("local")
                }
                Text("장부는 아이폰에 저장합니다. AI를 켜면 아이폰에서 선택한 서비스에 직접 요청합니다. 자체 서버나 PC 연결은 필요하지 않습니다.").font(.caption)
                if mode == "personal" {
                    Picker("공급자", selection: $provider) {
                        Text("Groq").tag("groq"); Text("OpenRouter").tag("openrouter"); Text("Gemini").tag("gemini")
                    }.onChange(of: provider) { _, _ in key = ""; modelID = "" }
                    SecureField("API 키 (비워두면 기존 키 유지)", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("선택한 서비스에서 API 키 발급받기", destination: URL(string: provider == "groq" ? "https://console.groq.com/keys" : provider == "openrouter" ? "https://openrouter.ai/settings/keys" : "https://aistudio.google.com/apikey")!)
                    TextField("모델 ID (선택)", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("이 공급자의 저장된 키 삭제", role: .destructive) {
                        do { try Secrets.set("api-" + provider, ""); key = ""; model.message = "API 키를 삭제했습니다." }
                        catch { model.message = error.localizedDescription }
                    }
                }
                if mode != "local" {
                    Toggle("AI 분석을 위한 집계 데이터 전송 동의", isOn: $consent)
                    Text("기간별 수입·지출, 분류별 합계와 증감을 선택한 서비스로 전송합니다. 원본 SMS, 이름, 카드·계좌번호, 가맹점 원문은 보내지 않습니다. 개인 API 실패 시 다른 업체로 자동 전송하지 않습니다.").font(.caption)
                }
            }
            Section {
                Button("설정 저장") { save() }.font(.headline)
            }
            Section("4 · 자동화 연결과 위젯") {
                Text("카드번호·CVC·계좌 비밀번호를 요청하지 않습니다. 문자에 포함된 카드 식별정보는 저장 전에 가립니다. 취소와 환불은 원거래와 별도 기록합니다.").font(.caption)
                Button("알림 허용 · \(notificationState)") {
                    Task {
                        do {
                            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                            notificationState = allowed ? "허용됨" : "꺼짐"
                        } catch { model.message = error.localizedDescription }
                    }
                }
                NavigationLink("사용할 카드사 선택·추가") { CardSourcesView() }
                NavigationLink("문자 자동 기록 연결 안내") { SetupGuide(kind: "sms") }
                NavigationLink("야간·주간·월간·연간 결산 연결 안내") { SetupGuide(kind: "audit") }
                NavigationLink("홈 화면 위젯 추가 안내") { SetupGuide(kind: "widget") }
                LabeledContent("마지막 문자 수신", value: model.snapshot["lastSMS"] as? String ?? "아직 확인되지 않음")
                LabeledContent("마지막 결산 실행", value: model.snapshot["lastAudit"] as? String ?? "아직 확인되지 않음")
                Text("연결 안내 완료와 실제 자동 실행 확인은 다릅니다. 앱은 다른 앱의 자동화 설정을 직접 검사할 수 없습니다.").font(.caption)
            }
        }.navigationTitle("설정")
            .task {
                let s = model.settings
                expected = String(s["expectedSalary"] as? Int ?? 0); savings = String(s["savingsGoal"] as? Int ?? 0)
                salaryDay = s["salaryDay"] as? Int ?? 25; reminderHour = s["reminderHour"] as? Int ?? 20
                auditHour = s["auditHour"] as? Int ?? 22; weekEnd = s["weekEnd"] as? Int ?? 0
                mode = s["aiMode"] as? String ?? "local"; provider = s["provider"] as? String ?? "groq"
                modelID = s["model"] as? String ?? ""; consent = s["consent"] as? Bool ?? false
                let access = await UNUserNotificationCenter.current().notificationSettings()
                notificationState = access.authorizationStatus == .authorized ? "허용됨" : "확인 필요"
            }
            .sheet(isPresented: $showPlan) { NavigationStack { PlansView() } }
    }
    private func save() {
        guard let income = Int64(expected), let goal = Int64(savings) else { model.message = "월급과 저축액을 숫자로 입력해주세요."; return }
        do {
            if !key.isEmpty { try Secrets.set("api-" + provider, key); key = "" }
            var s = model.settings
            s["expectedSalary"] = income; s["savingsGoal"] = goal; s["salaryDay"] = salaryDay
            s["reminderHour"] = reminderHour; s["auditHour"] = auditHour; s["weekEnd"] = weekEnd
            s["aiMode"] = mode; s["provider"] = provider; s["model"] = modelID; s["consent"] = consent; s["setupDone"] = true
            if model.save("settings", ["settings": s]) {
                Task {
                    do { try await Notices.scheduleSalary(s); model.message = "설정을 저장했습니다. 자동화 연결 안내를 이어서 확인해주세요." }
                    catch { model.message = "설정은 저장했지만 알림 예약에 실패했습니다: " + error.localizedDescription }
                }
            }
        } catch { model.message = error.localizedDescription }
    }
}

struct CardSourcesView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var editingID: String?
    @State private var name = ""
    @State private var keywords = ""
    private var sources: [[String: Any]] { model.settings["cardSources"] as? [[String: Any]] ?? [] }
    var body: some View {
        Form {
            Section("감지할 카드사") {
                ForEach(sources.indices, id: \.self) { index in
                    HStack {
                        Button {
                            let source = sources[index]
                            editingID = source["id"] as? String
                            name = source["name"] as? String ?? ""
                            keywords = (source["keywords"] as? [String] ?? []).joined(separator: ", ")
                        } label: {
                            VStack(alignment: .leading) {
                                Text(sources[index]["name"] as? String ?? "")
                                Text((sources[index]["keywords"] as? [String] ?? []).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { sources[index]["enabled"] as? Bool ?? true },
                            set: { enabled in update(index: index, enabled: enabled) }
                        )).labelsHidden()
                    }
                }
            }
            Section(editingID == nil ? "카드사 직접 추가" : "카드사 수정") {
                TextField("표시 이름 (예: 지역은행 체크카드)", text: $name)
                TextField("감지어, 쉼표로 구분", text: $keywords)
                Text("문자·메일·OCR 결과에 들어 있는 카드사명이나 발신 표기를 넣습니다. 카드번호나 이름은 넣지 마세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("저장") { saveSource() }
                if editingID != nil {
                    Button("새 카드사 입력") { editingID = nil; name = ""; keywords = "" }
                }
            }
        }.navigationTitle("카드사 선택")
    }
    private func update(index: Int, enabled: Bool) {
        var settings = model.settings, items = sources
        guard items.indices.contains(index) else { return }
        items[index]["enabled"] = enabled; settings["cardSources"] = items
        _ = model.save("settings", ["settings": settings])
    }
    private func saveSource() {
        let words = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !words.isEmpty else {
            model.message = "카드사 이름과 감지어를 입력해주세요."; return
        }
        var settings = model.settings, items = sources
        let id = editingID ?? "custom-" + UUID().uuidString
        items.removeAll { $0["id"] as? String == id }
        items.append(["id": id, "name": name, "keywords": words, "enabled": true])
        settings["cardSources"] = items
        if model.save("settings", ["settings": settings]) { editingID = nil; name = ""; keywords = "" }
    }
}

struct PlansView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var name = ""
    @State private var amount = ""
    @State private var merchant = ""
    @State private var day = 1
    @State private var editingID: String?
    var body: some View {
        Form {
            Section("저장된 고정비 · 눌러서 수정") {
                let plans = model.settings["plans"] as? [[String: Any]] ?? []
                ForEach(plans.indices, id: \.self) { i in
                    Button {
                        editingID = plans[i]["id"] as? String; name = plans[i]["name"] as? String ?? ""
                        amount = String(plans[i]["amount"] as? Int ?? 0); merchant = plans[i]["merchant"] as? String ?? ""; day = plans[i]["day"] as? Int ?? 1
                    } label: { LabeledContent(plans[i]["name"] as? String ?? "", value: won(plans[i]["amount"])) }
                }
            }
            Section(editingID == nil ? "고정비 추가" : "고정비 수정") {
                TextField("이름", text: $name)
                TextField("월 금액", text: $amount).keyboardType(.numberPad)
                Stepper("결제 예정일 \(day)일", value: $day, in: 1...31)
                TextField("SMS 가맹점명 정확히 일치 (선택)", text: $merchant)
                Text("문자에 표시되는 가맹점·금액·결제일이 모두 맞을 때만 자동 연결됩니다. 계좌이체 고정비는 수동 기록에서 연결할 수 있습니다.").font(.caption)
                Button("저장") {
                    guard let value = Int64(amount), !name.isEmpty else { model.message = "고정비 이름과 금액을 입력해주세요."; return }
                    var s = model.settings, plans = s["plans"] as? [[String: Any]] ?? []
                    let id = editingID ?? UUID().uuidString
                    plans.removeAll { $0["id"] as? String == id }
                    plans.append(["id": id, "name": name, "amount": value, "merchant": merchant, "day": day])
                    s["plans"] = plans
                    if model.save("settings", ["settings": s]) { editingID = nil; name = ""; amount = ""; merchant = "" }
                }
                if editingID != nil { Button("새 항목 입력") { editingID = nil; name = ""; amount = ""; merchant = "" } }
            }
        }.navigationTitle("고정비·구독 관리")
    }
}

struct SetupGuide: View {
    @EnvironmentObject var model: BudgetModel
    let kind: String
    var body: some View {
        List {
            if kind == "sms" {
                Text("우선 설정 → 사용할 카드사 선택·추가에서 실제 카드만 켭니다.")
                Text("SMS: 단축어 → 자동화 → 메시지에서 카드사 발신자를 고르고 ‘즉시 실행’ → ‘카드 거래 알림 기록’을 추가한 뒤 수신 본문을 연결합니다. 승인만 필터링하지 않아야 취소·환불도 잡힙니다.")
                Text("Wallet: 카드가 Apple Pay를 지원하면 자동화 → 거래에서 카드를 선택하고 거래 정보를 ‘Wallet 거래 기록’ 동작의 금액·가맹점에 연결합니다.")
                Text("이메일: 자동화 → 이메일에서 카드사 발신자를 고르고 메일 본문을 ‘카드 거래 알림 기록’에 연결합니다.")
                Text("푸시만 오는 카드: 거래 탭의 ‘푸시 화면 가져오기’에서 캡처를 선택하면 아이폰 안에서 OCR 후 앱의 이미지 사본을 버립니다. 사진 앱의 캡처는 사용자가 삭제할 수 있습니다. 알림을 길게 눌러 복사할 수 있으면 붙여넣기도 가능합니다.")
                Text("iPhone 16 Pro 빠른 기록: 단축어에 ‘스크린샷 찍기’ → ‘푸시 화면 OCR 기록’을 넣고 결과 이미지와 카드사 이름을 연결한 뒤 액션 버튼에 지정합니다. 푸시를 펼친 상태에서 버튼 한 번으로 기록할 수 있습니다.")
                Text("iOS는 모아 가계부가 다른 카드사 앱의 푸시 본문을 백그라운드에서 직접 읽는 것을 허용하지 않습니다. 위 경로를 카드별로 우선 적용하고, 어느 경로도 없는 카드만 화면 가져오기를 사용합니다.")
            } else if kind == "audit" {
                Text("1. 단축어 앱 → 자동화 → 시간 → 매일 \(model.settings["auditHour"] as? Int ?? 22):00을 선택합니다.")
                Text("2. ‘즉시 실행’을 선택하고 ‘예약 결산 실행’ 동작을 추가합니다.")
                Text("3. 앱이 설정한 주간 마감일·월말·연말을 판별합니다. 기간별 자동화를 따로 만들 필요는 없습니다.")
                Text("4. 시간을 변경하면 이 자동화의 시간도 함께 변경해주세요. 네트워크 분석이 중단되면 숫자 결산을 먼저 보존합니다.")
            } else {
                Text("1. 홈 화면의 빈 곳을 길게 누릅니다.")
                Text("2. 편집 → 위젯 추가 → ‘모아 가계부’를 찾습니다.")
                Text("3. 작은 위젯 또는 중간 위젯을 선택해 추가합니다.")
                Text("위젯에는 남은 생활비와 하루 권장액을 표시합니다. iOS가 갱신 시간을 결정하므로 마지막 업데이트 시간도 함께 확인하세요.")
            }
            if kind != "widget" { Link("단축어 앱 열기", destination: URL(string: "shortcuts://")!) }
            Button("안내에 따라 설정했어요") {
                var s = model.settings
                s[kind == "sms" ? "smsGuideDone" : kind == "audit" ? "auditGuideDone" : "widgetGuideDone"] = true
                if model.save("settings", ["settings": s]) { model.message = "설정 안내를 완료했습니다. 자동화는 실제 실행 기록으로 확인할 수 있습니다." }
            }
        }.navigationTitle(kind == "widget" ? "위젯 추가" : "자동화 연결")
    }
}
