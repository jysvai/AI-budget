import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

struct SettingsView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var notificationState = "확인 중"
    @State private var widgetState = "확인 중"

    private var setupCount: Int {
        ["setupDone", "smsGuideDone", "auditGuideDone", "widgetGuideDone"]
            .filter { model.settings[$0] as? Bool == true }.count
    }

    var body: some View {
        MoaPage {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("내 가계부 설정").font(MoaFont.title2).foregroundStyle(.white)
                        Text("필요한 항목만 골라서 바꿀 수 있어요").font(MoaFont.subheadline).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Text("\(setupCount)/4")
                        .font(MoaFont.title3).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.white.opacity(0.16), in: Circle())
                }
                ProgressView(value: Double(setupCount), total: 4).tint(.white)
                NavigationLink { QuickSetupView() } label: {
                    Label(model.settings["setupDone"] as? Bool == true ? "빠른 설정 다시 보기" : "빠른 설정 시작", systemImage: "wand.and.stars")
                        .font(MoaFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(MoaTheme.teal)
                }
            }
            .padding(20)
            .background(MoaTheme.hero, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

            MoaCard {
                MoaSettingsLink(
                    title: "예산과 알림 시간",
                    subtitle: "월급, 저축 목표, 월급일과 결산 시간",
                    systemImage: "wonsign.circle.fill", tint: MoaTheme.teal
                ) { BudgetPreferencesView() }
                Divider().padding(.leading, 58)
                MoaSettingsLink(
                    title: "고정비와 구독",
                    subtitle: "월세, 통신비, 구독료를 미리 확보",
                    systemImage: "calendar.badge.checkmark", tint: .indigo
                ) { PlansView() }
                Divider().padding(.leading, 58)
                MoaSettingsLink(
                    title: "AI 분석",
                    subtitle: model.settings["aiMode"] as? String == "personal" ? "개인 API 사용 중" : "기기 내 숫자 결산",
                    systemImage: "sparkles", tint: MoaTheme.coral
                ) { AISettingsView() }
            }

            MoaSectionTitle(title: "연결 상태", subtitle: "권한과 자동 기록을 한곳에서 확인하세요")
            MoaCard {
                HStack {
                    Label("알림", systemImage: "bell.fill").font(MoaFont.subheadlineBold)
                    Spacer()
                    MoaStatusPill(text: notificationState, systemImage: notificationState == "허용됨" ? "checkmark" : "exclamationmark")
                }
                Divider()
                HStack {
                    Label("홈 화면 위젯", systemImage: "square.grid.2x2.fill").font(MoaFont.subheadlineBold)
                    Spacer()
                    MoaStatusPill(text: widgetState, systemImage: widgetState == "추가됨" ? "checkmark" : "plus")
                }
                Divider()
                HStack {
                    Label("장부 공유", systemImage: "arrow.triangle.2.circlepath").font(MoaFont.subheadlineBold)
                    Spacer()
                    MoaStatusPill(
                        text: LedgerStore.sharedStorageDescription,
                        systemImage: model.sharedStorageAvailable ? "checkmark" : "iphone",
                        color: model.sharedStorageAvailable ? MoaTheme.teal : .orange
                    )
                }
                NavigationLink { AutomationCenterView() } label: {
                    Text("자동화 센터 열기").font(MoaFont.headline).frame(maxWidth: .infinity).padding(.top, 6)
                }
            }

            MoaCard {
                MoaSettingsLink(
                    title: "개인정보 보호",
                    subtitle: "카드번호 마스킹과 저장 범위 확인",
                    systemImage: "lock.shield.fill", tint: .green
                ) { PrivacySettingsView() }
            }
        }
        .navigationTitle("설정")
        .task { await refreshStatus() }
    }

    @MainActor private func refreshStatus() async {
        let access = await UNUserNotificationCenter.current().notificationSettings()
        notificationState = switch access.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "허용됨"
        case .denied: "꺼짐"
        default: "설정 필요"
        }
        WidgetCenter.shared.getCurrentConfigurations { result in
            Task { @MainActor in
                widgetState = (try? result.get()).map { $0.isEmpty ? "미추가" : "추가됨" } ?? "확인 불가"
            }
        }
    }
}

struct QuickSetupView: View {
    @EnvironmentObject var model: BudgetModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var expected = ""
    @State private var savings = ""
    @State private var salaryDay = 25
    @State private var reminderHour = 20
    @State private var auditHour = 22
    @State private var weekEnd = 0

    var body: some View {
        MoaPage {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(step + 1) / 3").font(MoaFont.captionBold).foregroundStyle(MoaTheme.teal)
                ProgressView(value: Double(step + 1), total: 3).tint(MoaTheme.teal)
            }
            MoaCard {
                if step == 0 { moneyStep }
                else if step == 1 { scheduleStep }
                else { finishStep }
            }
            HStack {
                if step > 0 { Button("이전") { withAnimation { step -= 1 } }.buttonStyle(.bordered) }
                Spacer()
                if step < 2 {
                    Button("다음") {
                        guard step != 0 || (Int64(expected) != nil && Int64(savings) != nil) else {
                            model.message = "월급과 저축 목표를 숫자로 입력해주세요."; return
                        }
                        withAnimation { step += 1 }
                    }
                    .buttonStyle(.borderedProminent).tint(MoaTheme.teal)
                }
            }
        }
        .navigationTitle("빠른 설정")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private var moneyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("한 달 예산의 기준", systemImage: "wallet.pass.fill").font(MoaFont.title3).foregroundStyle(MoaTheme.teal)
            Text("월급에서 저축 목표와 고정비를 빼고 쓸 수 있는 생활비를 계산해요.").font(MoaFont.subheadline).foregroundStyle(.secondary)
            TextField("예상 월급", text: $expected).keyboardType(.numberPad).moaField()
            TextField("매달 저축 목표", text: $savings).keyboardType(.numberPad).moaField()
        }
    }

    private var scheduleStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("잊지 않도록 알려드릴게요", systemImage: "bell.badge.fill").font(MoaFont.title3).foregroundStyle(MoaTheme.teal)
            SettingPickerRow(title: "월급 확인일", value: "매월 \(salaryDay)일") {
                Picker("월급 확인일", selection: $salaryDay) { ForEach(1...31, id: \.self) { Text("\($0)일").tag($0) } }
            }
            SettingPickerRow(title: "월급 알림", value: hourLabel(reminderHour)) {
                Picker("월급 알림", selection: $reminderHour) { ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) } }
            }
            SettingPickerRow(title: "야간 결산", value: hourLabel(auditHour)) {
                Picker("야간 결산", selection: $auditHour) { ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) } }
            }
            SettingPickerRow(title: "주간 마감", value: weekday(weekEnd)) {
                Picker("주간 마감", selection: $weekEnd) { ForEach(0..<7) { Text(weekday($0)).tag($0) } }
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 46)).foregroundStyle(MoaTheme.teal)
            Text("기본 설정이 준비됐어요").font(MoaFont.title2)
            Text("AI는 개인정보를 외부로 보내지 않는 기기 내 결산으로 시작합니다. 카드 자동 기록과 개인 API는 자동화 센터에서 필요할 때 연결하세요.")
                .font(MoaFont.subheadline).foregroundStyle(.secondary)
            LabeledContent("예상 월급", value: expected.isEmpty ? "0원" : (Int64(expected) ?? 0).formatted() + "원")
            LabeledContent("저축 목표", value: savings.isEmpty ? "0원" : (Int64(savings) ?? 0).formatted() + "원")
            LabeledContent("결산 시간", value: hourLabel(auditHour))
            MoaPrimaryButton(title: "이 설정으로 시작", systemImage: "checkmark") { save() }
        }
    }

    private func load() {
        let s = model.settings
        expected = String((s["expectedSalary"] as? NSNumber)?.int64Value ?? 0)
        savings = String((s["savingsGoal"] as? NSNumber)?.int64Value ?? 0)
        salaryDay = s["salaryDay"] as? Int ?? 25
        reminderHour = s["reminderHour"] as? Int ?? 20
        auditHour = s["auditHour"] as? Int ?? 22
        weekEnd = s["weekEnd"] as? Int ?? 0
    }

    private func save() {
        guard let income = Int64(expected), let goal = Int64(savings) else { return }
        var s = model.settings
        s["expectedSalary"] = income; s["savingsGoal"] = goal; s["salaryDay"] = salaryDay
        s["reminderHour"] = reminderHour; s["auditHour"] = auditHour; s["weekEnd"] = weekEnd
        s["setupDone"] = true
        guard model.save("settings", ["settings": s]) else { return }
        Task {
            do { try await Notices.scheduleSalary(s); dismiss() }
            catch { model.message = "설정은 저장했지만 알림 예약에 실패했습니다: \(error.localizedDescription)" }
        }
    }
}

struct SettingPickerRow<Content: View>: View {
    let title: String
    let value: String
    let content: Content
    init(title: String, value: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.value = value; self.content = content()
    }
    var body: some View {
        HStack {
            Text(title).font(MoaFont.subheadlineBold)
            Spacer()
            Menu { content } label: {
                HStack(spacing: 5) { Text(value); Image(systemName: "chevron.up.chevron.down") }
                    .font(MoaFont.subheadline).foregroundStyle(MoaTheme.teal)
            }
        }
        .padding(13)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct BudgetPreferencesView: View {
    @EnvironmentObject var model: BudgetModel
    @Environment(\.dismiss) private var dismiss
    @State private var expected = ""
    @State private var savings = ""
    @State private var salaryDay = 25
    @State private var reminderHour = 20
    @State private var auditHour = 22
    @State private var weekEnd = 0

    var body: some View {
        Form {
            Section("월 예산") {
                TextField("예상 월급", text: $expected).keyboardType(.numberPad)
                TextField("저축 목표", text: $savings).keyboardType(.numberPad)
                Text("생활비 = 월급 − 저축 목표 − 고정비 예약액").font(MoaFont.caption).foregroundStyle(.secondary)
            }
            Section("알림과 결산") {
                Picker("월급 확인일", selection: $salaryDay) { ForEach(1...31, id: \.self) { Text("\($0)일").tag($0) } }
                Picker("월급 알림", selection: $reminderHour) { ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) } }
                Picker("야간 결산", selection: $auditHour) { ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) } }
                Picker("주간 마감", selection: $weekEnd) { ForEach(0..<7) { Text(weekday($0)).tag($0) } }
            }
            Section { Button("변경사항 저장") { save() }.font(MoaFont.headline).frame(maxWidth: .infinity) }
        }
        .navigationTitle("예산과 시간")
        .task { load() }
    }

    private func load() {
        let s = model.settings
        expected = String((s["expectedSalary"] as? NSNumber)?.int64Value ?? 0)
        savings = String((s["savingsGoal"] as? NSNumber)?.int64Value ?? 0)
        salaryDay = s["salaryDay"] as? Int ?? 25; reminderHour = s["reminderHour"] as? Int ?? 20
        auditHour = s["auditHour"] as? Int ?? 22; weekEnd = s["weekEnd"] as? Int ?? 0
    }

    private func save() {
        guard let income = Int64(expected), let goal = Int64(savings) else { model.message = "금액을 숫자로 입력해주세요."; return }
        var s = model.settings
        s["expectedSalary"] = income; s["savingsGoal"] = goal; s["salaryDay"] = salaryDay
        s["reminderHour"] = reminderHour; s["auditHour"] = auditHour; s["weekEnd"] = weekEnd; s["setupDone"] = true
        if model.save("settings", ["settings": s]) {
            Task { try? await Notices.scheduleSalary(s) }
            model.message = "예산과 시간을 저장했습니다."
            dismiss()
        }
    }
}

struct AISettingsView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var mode = "local"
    @State private var provider = "groq"
    @State private var modelID = ""
    @State private var key = ""
    @State private var consent = false
    @AppStorage("lastGroqModel") private var lastGroqModel = ""

    var body: some View {
        Form {
            Section {
                Picker("분석 방식", selection: $mode) {
                    Label("기기 내 결산", systemImage: "iphone").tag("local")
                    Label("개인 API", systemImage: "sparkles").tag("personal")
                }.pickerStyle(.inline)
                Text(mode == "local" ? "외부 전송 없이 수입·지출 숫자를 정리합니다." : "아이폰에서 선택한 AI 서비스로 집계값만 직접 보냅니다.")
                    .font(MoaFont.caption).foregroundStyle(.secondary)
            }
            if mode == "personal" {
                Section("개인 API") {
                    Picker("서비스", selection: $provider) {
                        Text("Groq").tag("groq"); Text("OpenRouter").tag("openrouter"); Text("Gemini").tag("gemini")
                    }.onChange(of: provider) { _, _ in key = ""; modelID = "" }
                    SecureField("API 키 · 비워두면 기존 키 유지", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("API 키 발급 페이지 열기", destination: providerURL)
                    if provider == "groq" {
                        Picker("우선 모델", selection: $modelID) {
                            Text("자동 순환 · 추천").tag("")
                            Text("GPT-OSS 120B").tag("openai/gpt-oss-120b")
                            Text("Qwen 3.8 27B").tag("qwen/qwen3.8-27b")
                            Text("GPT-OSS 20B").tag("openai/gpt-oss-20b")
                            Text("Compound Mini").tag("groq/compound-mini")
                            Text("Compound").tag("groq/compound")
                        }
                        if !lastGroqModel.isEmpty { LabeledContent("최근 성공", value: lastGroqModel).font(MoaFont.caption) }
                        Text("선택 모델의 한도나 장애가 감지되면 사용 가능한 다른 Groq 모델로 자동 전환합니다.")
                            .font(MoaFont.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("모델 ID · 선택", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Toggle("집계 데이터 전송에 동의", isOn: $consent)
                    Text("원본 알림, 카드·계좌번호, 이름과 가맹점 원문은 AI로 보내지 않습니다.")
                        .font(MoaFont.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("AI 설정 저장") { save() }.font(MoaFont.headline).frame(maxWidth: .infinity)
                if mode == "personal" {
                    Button("저장된 \(provider) 키 삭제", role: .destructive) {
                        do { try Secrets.set("api-" + provider, ""); key = ""; model.message = "API 키를 삭제했습니다." }
                        catch { model.message = error.localizedDescription }
                    }
                }
            }
        }
        .navigationTitle("AI 분석")
        .task {
            let s = model.settings
            mode = s["aiMode"] as? String ?? "local"; provider = s["provider"] as? String ?? "groq"
            modelID = s["model"] as? String ?? ""; consent = s["consent"] as? Bool ?? false
        }
    }

    private var providerURL: URL {
        URL(string: provider == "groq" ? "https://console.groq.com/keys" : provider == "openrouter" ? "https://openrouter.ai/settings/keys" : "https://aistudio.google.com/apikey")!
    }

    private func save() {
        guard mode == "local" || consent else { model.message = "개인 API 사용에는 집계 데이터 전송 동의가 필요합니다."; return }
        do {
            if !key.isEmpty { try Secrets.set("api-" + provider, key); key = "" }
            var s = model.settings
            s["aiMode"] = mode; s["provider"] = provider; s["model"] = modelID; s["consent"] = mode == "personal" && consent
            if model.save("settings", ["settings": s]) { model.message = "AI 설정을 저장했습니다." }
        } catch { model.message = error.localizedDescription }
    }
}

struct AutomationCenterView: View {
    @EnvironmentObject var model: BudgetModel
    @State private var notificationState = "확인 중"
    @State private var widgetState = "확인 중"

    var body: some View {
        MoaPage {
            MoaCard {
                Label("알림", systemImage: "bell.fill").font(MoaFont.title3)
                Text("월급 확인과 결산 완료 알림에 사용합니다.").font(MoaFont.subheadline).foregroundStyle(.secondary)
                HStack {
                    MoaStatusPill(text: notificationState, systemImage: notificationState == "허용됨" ? "checkmark" : "bell.slash")
                    Spacer()
                    Button(notificationState == "꺼짐" ? "iPhone 설정 열기" : "허용 요청") { requestNotification() }
                        .buttonStyle(.borderedProminent).tint(MoaTheme.teal)
                }
            }
            MoaCard {
                Label("홈 화면 위젯", systemImage: "square.grid.2x2.fill").font(MoaFont.title3)
                Text("위젯에는 별도의 허용 팝업이 없습니다. 홈 화면에 추가하면 바로 작동합니다.")
                    .font(MoaFont.subheadline).foregroundStyle(.secondary)
                HStack {
                    MoaStatusPill(text: widgetState, systemImage: widgetState == "추가됨" ? "checkmark" : "plus")
                    Spacer()
                    MoaStatusPill(
                        text: LedgerStore.sharedStorageDescription,
                        systemImage: model.sharedStorageAvailable ? "arrow.triangle.2.circlepath" : "iphone",
                        color: model.sharedStorageAvailable ? MoaTheme.teal : .orange
                    )
                }
                NavigationLink("위젯 추가 방법 보기") { SetupGuide(kind: "widget") }
                    .font(MoaFont.headline)
            }
            MoaCard {
                MoaSettingsLink(title: "카드사 선택", subtitle: "사용하는 카드만 켜고 감지어 조정", systemImage: "creditcard.fill", tint: .blue) { CardSourcesView() }
                Divider().padding(.leading, 58)
                MoaSettingsLink(title: "거래 자동 기록", subtitle: "문자·Wallet·화면 OCR 연결", systemImage: "bolt.fill", tint: .orange) { SetupGuide(kind: "sms") }
                Divider().padding(.leading, 58)
                MoaSettingsLink(title: "예약 결산", subtitle: "야간·주간·월말·연간 자동 분석", systemImage: "clock.arrow.2.circlepath", tint: .purple) { SetupGuide(kind: "audit") }
            }
            MoaCard {
                LabeledContent("마지막 거래 자동 수신", value: model.snapshot["lastSMS"] as? String ?? "아직 없음")
                Divider()
                LabeledContent("마지막 예약 결산", value: model.snapshot["lastAudit"] as? String ?? "아직 없음")
            }
        }
        .navigationTitle("자동화 센터")
        .task { await refresh() }
    }

    @MainActor private func refresh() async {
        let access = await UNUserNotificationCenter.current().notificationSettings()
        notificationState = switch access.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "허용됨"
        case .denied: "꺼짐"
        default: "설정 필요"
        }
        WidgetCenter.shared.getCurrentConfigurations { result in
            Task { @MainActor in widgetState = (try? result.get()).map { $0.isEmpty ? "미추가" : "추가됨" } ?? "확인 불가" }
        }
    }

    private func requestNotification() {
        Task {
            let current = await UNUserNotificationCenter.current().notificationSettings()
            if current.authorizationStatus == .denied {
                await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } else {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
            await refresh()
        }
    }
}

struct PrivacySettingsView: View {
    var body: some View {
        List {
            Section("아이폰에만 저장") {
                Label("장부 원본은 앱 또는 App Group 저장공간에 보관", systemImage: "iphone")
                Label("서버와 Windows PC 없이 동작", systemImage: "network.slash")
            }
            Section("자동 마스킹") {
                Label("카드·계좌 식별번호와 전화번호 마스킹", systemImage: "creditcard.trianglebadge.exclamationmark")
                Label("CVC·비밀번호는 입력받지 않음", systemImage: "lock.fill")
                Label("캡처는 기기 내 OCR 후 앱에 이미지 사본을 남기지 않음", systemImage: "text.viewfinder")
            }
            Section("AI 사용 시") {
                Text("개인 API를 선택하고 동의한 경우에만 기간별 합계와 분류별 증감이 해당 서비스로 전송됩니다. 원본 알림과 카드번호는 보내지 않습니다.")
            }
        }.navigationTitle("개인정보 보호")
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
            Section("사용하는 카드만 켜세요") {
                ForEach(sources.indices, id: \.self) { index in
                    HStack {
                        Button {
                            let source = sources[index]
                            editingID = source["id"] as? String; name = source["name"] as? String ?? ""
                            keywords = (source["keywords"] as? [String] ?? []).joined(separator: ", ")
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sources[index]["name"] as? String ?? "").font(MoaFont.subheadlineBold)
                                Text((sources[index]["keywords"] as? [String] ?? []).joined(separator: " · "))
                                    .font(MoaFont.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { sources[index]["enabled"] as? Bool ?? true },
                            set: { update(index: index, enabled: $0) }
                        )).labelsHidden()
                    }
                }
            }
            Section(editingID == nil ? "직접 추가" : "선택한 카드사 수정") {
                TextField("표시 이름", text: $name)
                TextField("감지어 · 쉼표로 구분", text: $keywords)
                Text("문자나 OCR 결과에 표시되는 카드사 이름만 넣으세요. 카드번호는 넣지 않습니다.").font(MoaFont.caption).foregroundStyle(.secondary)
                Button("카드사 저장") { saveSource() }
                if editingID != nil { Button("새 카드사 입력") { editingID = nil; name = ""; keywords = "" } }
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
                if plans.isEmpty { Text("아직 등록한 고정비가 없어요.").foregroundStyle(.secondary) }
                ForEach(plans.indices, id: \.self) { index in
                    Button {
                        editingID = plans[index]["id"] as? String; name = plans[index]["name"] as? String ?? ""
                        amount = String((plans[index]["amount"] as? NSNumber)?.int64Value ?? 0)
                        merchant = plans[index]["merchant"] as? String ?? ""; day = plans[index]["day"] as? Int ?? 1
                    } label: {
                        LabeledContent(plans[index]["name"] as? String ?? "", value: won(plans[index]["amount"]))
                    }
                }
            }
            Section(editingID == nil ? "고정비 추가" : "고정비 수정") {
                TextField("이름 · 예: 월세", text: $name)
                TextField("매달 금액", text: $amount).keyboardType(.numberPad)
                Picker("결제 예정일", selection: $day) { ForEach(1...31, id: \.self) { Text("\($0)일").tag($0) } }
                TextField("문자 가맹점명 · 선택", text: $merchant)
                Button("저장") { savePlan() }
                if editingID != nil { Button("새 항목 입력") { editingID = nil; name = ""; amount = ""; merchant = "" } }
            }
        }.navigationTitle("고정비·구독")
    }

    private func savePlan() {
        guard let value = Int64(amount), value >= 0, !name.isEmpty else { model.message = "고정비 이름과 금액을 입력해주세요."; return }
        var s = model.settings, plans = s["plans"] as? [[String: Any]] ?? []
        let id = editingID ?? UUID().uuidString
        plans.removeAll { $0["id"] as? String == id }
        plans.append(["id": id, "name": name, "amount": value, "merchant": merchant, "day": day])
        s["plans"] = plans
        if model.save("settings", ["settings": s]) { editingID = nil; name = ""; amount = ""; merchant = "" }
    }
}

struct SetupGuide: View {
    @EnvironmentObject var model: BudgetModel
    let kind: String
    private var steps: [(String, String)] {
        if kind == "sms" {
            return [
                ("카드사 선택", "자동화 센터에서 실제 사용하는 카드만 켜세요."),
                ("단축어 자동화 만들기", "메시지 또는 이메일 수신 자동화에 ‘카드 거래 알림 기록’을 추가하고 본문을 연결하세요."),
                ("취소·환불도 포함", "승인만 필터링하지 않아야 취소와 환불도 별도로 기록됩니다."),
                ("푸시만 오는 카드", "거래 탭의 ‘화면 가져오기’로 캡처를 선택하면 기기에서 OCR합니다.")
            ]
        } else if kind == "audit" {
            return [
                ("시간 자동화", "단축어 → 자동화 → 시간 → 매일 \(model.settings["auditHour"] as? Int ?? 22):00을 선택하세요."),
                ("즉시 실행", "실행 전 묻기를 끄고 ‘예약 결산 실행’ 동작을 추가하세요."),
                ("한 번만 만들기", "앱이 주간 마감·월말·연말을 판별하므로 기간마다 따로 만들 필요가 없습니다.")
            ]
        }
        return [
            ("홈 화면 길게 누르기", "빈 곳을 길게 누른 다음 편집 → 위젯 추가를 선택하세요."),
            ("모아 검색", "‘모아 가계부’를 찾아 작은 또는 중간 위젯을 선택하세요."),
            ("별도 권한 없음", "위젯에는 허용 팝업이 없습니다. 추가 후 모아 앱을 한 번 열면 최신 장부를 갱신합니다."),
            ("공유 상태", model.sharedStorageAvailable ? "현재 앱과 위젯의 장부 공유가 연결되어 있습니다." : "현재 설치 서명에서는 공유 저장소가 확인되지 않습니다. 위젯은 앱 열기 화면을 표시하며 장부 데이터는 앱 안에서 안전하게 유지됩니다.")
        ]
    }

    var body: some View {
        MoaPage {
            ForEach(steps.indices, id: \.self) { index in
                MoaCard {
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").font(MoaFont.headline).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(MoaTheme.teal, in: Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            Text(steps[index].0).font(MoaFont.headline)
                            Text(steps[index].1).font(MoaFont.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if kind != "widget" { Link("단축어 앱 열기", destination: URL(string: "shortcuts://")!).buttonStyle(.borderedProminent).tint(MoaTheme.teal) }
            MoaPrimaryButton(title: "설정 완료로 표시", systemImage: "checkmark") { complete() }
        }
        .navigationTitle(kind == "widget" ? "위젯 추가" : "자동화 연결")
    }

    private func complete() {
        var s = model.settings
        s[kind == "sms" ? "smsGuideDone" : kind == "audit" ? "auditGuideDone" : "widgetGuideDone"] = true
        if model.save("settings", ["settings": s]) { model.message = "완료로 표시했습니다. 실제 연결 상태는 자동화 센터에서 계속 확인할 수 있어요." }
    }
}

func hourLabel(_ hour: Int) -> String {
    let display = hour == 0 ? 12 : hour > 12 ? hour - 12 : hour
    return (hour < 12 ? "오전" : "오후") + " \(display)시"
}

func weekday(_ index: Int) -> String {
    ["일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"][min(max(index, 0), 6)]
}
