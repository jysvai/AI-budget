# [Tech Spec] iOS 기반 Zero-Touch AI 가계부 시스템

> **이 문서는 초기 v1 초안으로 보존합니다. 현재 구현 기준은 [v2 제품 명세](docs/product-spec-v2.md)와 [README](README.md)입니다.** 최종 구조는 네이티브 iOS 앱 + App Intents + 단축어 + WidgetKit이며 Scriptable을 사용하지 않습니다. 아래의 0.1초 실행 보장, iCloud 경합 없음, 기존 파서 및 고정된 무료 API 한도 가정은 현행 요구사항이 아닙니다.

> **문서 버전**: v1.0.0  
> **대상 환경**: iOS 17+, Scriptable, iOS Shortcuts (단축어), Google AI Studio (Gemini 2.5 Flash API)  
> **용도**: Codex / LLM 코딩 에이전트 인풋용 아키텍처 및 구현 명세서

---

## 1. 개요 (Overview)

### 1.1 배경 및 목적
* 기존 가계부 앱의 한계인 '수기 입력의 번거로움'과 '스크래핑 동기화 지연/오류'를 극복.
* 신용카드 승인 SMS를 OS 레벨에서 가로채 실시간으로 로컬 JSON에 기록하고, 매일 야간에 LLM을 통해 지출 패턴을 심층 분석/코칭하는 **완전 무인(Zero-Touch) 가계부 시스템** 구축.
* 앱 UI 진입 없이 **'결제 즉시 로컬 푸시'**, **'밤 10시 AI 결산 리포트'**, **'홈 화면 위젯'** 3가지 채널로만 상시 소비 통제력 확보.

### 1.2 핵심 기술 스택
* **OS / Trigger**: iOS 순정 단축어(Shortcuts) - 메시지 수신 자동화 & 시간 지정 자동화
* **런타임**: Scriptable (JavaScript / iOS 네이티브 API 브릿지)
* **스토리지**: iCloud Drive (`FileManager.iCloud()`) 내 JSON 파일 영속화
* **AI Engine**: Google Gemini 2.5 Flash API (무료 티어 활용, 분당 15 RPM 한도 내 일 1회 배치 호출)

---

## 2. 시스템 아키텍처 (2-Track Pipeline)

```text
[최초 1회 설정]
  └─ ledger_config.json (세후 소득, 고정비, 정기구독 키워드, 목표저축액)
        │
        ├───────────────────────────────────────────────────────┐
        ▼ (결제 승인 SMS 수신 시)                               ▼ (매일 22:00 도래 시)
┌──────────────────────────────────────┐       ┌──────────────────────────────────────┐
│     [Track 1: 실시간 감지 & 로깅]     │       │     [Track 2: 야간 AI 심층 결산]     │
│  iOS 단축어 메시지 자동화 (무인 실행) │       │  iOS 단축어 시간 지정 자동화 (22:00) │
└──────────────────┬───────────────────┘       └──────────────────┬───────────────────┘
                   ▼                                              ▼
┌──────────────────────────────────────┐       ┌──────────────────────────────────────┐
│  Scriptable: parse_sms.js            │       │  Scriptable: daily_audit.js          │
│  1. SMS 본문 정규식 파싱(금액, 상호) │       │  1. 오늘자 지출 트랜잭션 집계        │
│  2. 구독 결제 키워드 대조 (고정비)   │       │  2. 일일 권장치 vs 실제 지출 비교    │
│  3. 변동 생활비 누적 및 소진율 계산  │       │  3. Gemini 2.5 Flash API 호출        │
│  4. iCloud ledger JSON 즉각 갱신     │       │  4. AI 코칭 결과 JSON 저장           │
└──────────────────┬───────────────────┘       └──────────────────┬───────────────────┘
                   ▼                                              ▼
┌──────────────────────────────────────┐       ┌──────────────────────────────────────┐
│  즉시 로컬 푸시 알림 (0.1초 소요)    │       │  야간 코칭 푸시 알림                 │
│  "32,000원 결제 (스타벅스)           │       │  "[주의] 권장 예산 대비 1.8만 원 초과│
│   월 가용 예산의 28.4% 소진 중"      │       │   배민/카페 지출 조정 필요"          │
└──────────────────┬───────────────────┘       └──────────────────┬───────────────────┘
                   │                                              │
                   └───────────────────────┬──────────────────────┘
                                           ▼
                       ┌──────────────────────────────────────┐
                       │     [Track 3: 상시 모니터링 위젯]     │
                       │  Scriptable Home Screen Widget       │
                       │  - 월 경과율 vs 예산 소진율 게이지   │
                       │  - 내일 쓸 수 있는 권장 일일 예산    │
                       │  - 최근 AI 분석 등급 배지 (안정/경고)│
                       └──────────────────────────────────────┘
```

---

## 3. 데이터 구조 설계 (Data Schemas)

모든 데이터는 `iCloud Drive/Scriptable/` 디렉터리에 저장됩니다.

### 3.1 `ledger_config.json` (환경설정)
고정비와 정기 구독료를 사전 정의하여 순수 변동지출 한도 산출 및 중복 차감 방지.

```json
{
  "version": "1.0",
  "monthlyIncome": 3500000,
  "targetSavings": 1000000,
  "fixedExpenses": {
    "rent": { "name": "월세 및 관리비", "amount": 650000, "type": "transfer", "day": 25 },
    "telecom": { "name": "통신비", "amount": 85000, "type": "autopay", "day": 15 },
    "insurance": { "name": "보장성 보험", "amount": 120000, "type": "autopay", "day": 10 }
  },
  "subscriptions": [
    { "name": "OpenAI / Claude", "matchKeyword": "OPENAI", "amount": 30000, "day": 5 },
    { "name": "Google Gemini", "matchKeyword": "GOOGLE", "amount": 29000, "day": 12 },
    { "name": "YouTube Premium", "matchKeyword": "YOUTUBE", "amount": 14900, "day": 18 },
    { "name": "쿠팡 와우", "matchKeyword": "쿠팡", "amount": 7890, "day": 22 },
    { "name": "네이버플러스", "matchKeyword": "네이버파이낸셜", "amount": 4900, "day": 28 }
  ]
}
```

### 3.2 `monthly_ledger_{YYYYMM}.json` (월간 트랜잭션 및 상태)
```json
{
  "yearMonth": "2026-09",
  "monthlyIncome": 3500000,
  "fixedBudget": 855000,
  "subscriptionBudget": 86690,
  "targetSavings": 1000000,
  "netVariableBudget": 1558310,
  "totalVariableSpent": 482000,
  "totalFixedSpent": 85000,
  "lastUpdated": "2026-09-17T10:30:00+09:00",
  "latestAudit": {
    "date": "2026-09-16",
    "status": "주의",
    "summary": "일일 권장액(4.2만) 대비 2.3만 원 초과. 배달 식비 지출이 주요 원인.",
    "recommendedNextDailyBudget": 38500
  },
  "transactions": [
    {
      "id": "tx_1726532400123",
      "timestamp": "2026-09-17T09:40:00+09:00",
      "rawMessage": "[Web발신] 신한카드 승인 6,500원 스타벅스성남 09/17 09:40 누적 482,000원",
      "store": "스타벅스성남",
      "amount": 6500,
      "type": "variable",
      "isSubscription": false
    },
    {
      "id": "tx_1726102800456",
      "timestamp": "2026-09-12T11:20:00+09:00",
      "rawMessage": "[Web발신] 신한카드 해외승인 USD 20.00 GOOGLE*TEMPORARY",
      "store": "GOOGLE*TEMPORARY",
      "amount": 29000,
      "type": "subscription",
      "isSubscription": true,
      "subName": "Google Gemini"
    }
  ]
}
```

---

## 4. 핵심 비즈니스 로직 및 수식 (Business Logic)

### 4.1 순수 변동지출 한도 계산 (Net Variable Budget)
$$	ext{NetVariableBudget} = 	ext{MonthlyIncome} - \sum 	ext{FixedExpenses} - \sum 	ext{Subscriptions} - 	ext{TargetSavings}$$
* 소득에서 고정비, 정기구독, 저축액을 원천 격리함으로써 '가짜 여유(소득 착시)'를 원천 차단.

### 4.2 구독 결제 이중 차감 방지 (Subscription Filtering)
1. 승인 문자에서 추출된 `store` 문자열과 `config.subscriptions[].matchKeyword` 대조.
2. **일치(Match)**:
   * `type = "subscription"` 태그 부여.
   * `totalVariableSpent`에 가산하지 않음 (변동 생활비 한도 훼손 방지).
   * 알림: `[정기결제] {subName} {amount}원 처리 (사전 예산 반영 완료)`
3. **불일치(Unmatch)**:
   * `type = "variable"` 태그 부여.
   * `totalVariableSpent += amount`.
   * 알림: 실시간 생활비 소진율 및 잔여 예산 통보.

### 4.3 동적 일일 권장 예산 수식 (Dynamic Daily Budget)
$$	ext{DaysRemaining} = 	ext{DaysInMonth} - 	ext{CurrentDay} + 1$$
$$	ext{RecommendedDailyBudget} = rac{	ext{NetVariableBudget} - 	ext{TotalVariableSpent}}{	ext{DaysRemaining}}$$
* 월 중반 과소비가 발생하면 남은 일수의 일일 가용액이 자동으로 낮아져 복구 궤도 자동 형성.

---

## 5. Gemini 2.5 Flash API 명세 (야간 결산용)

* **트리거**: 매일 22:00 iOS 단축어 자동화
* **엔드포인트**: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={API_KEY}`
* **Generation Config**:
  ```json
  {
    "temperature": 0.2,
    "maxOutputTokens": 120,
    "responseMimeType": "application/json"
  }
  ```

### 5.1 Prompt Input Payload
```json
{
  "systemInstruction": "당신은 엄격하고 현실적인 1:1 개인 재무 코치입니다. 오늘 하루 발생한 지출 내역을 바탕으로 낭비 지출을 냉정히 지적하고 내일의 행동 강령을 제시하세요. 반드시 지정된 JSON 포맷으로만 응답하십시오.",
  "prompt": {
    "date": "2026-09-17",
    "monthlyIncome": 3500000,
    "netVariableBudget": 1558310,
    "totalSpentSoFar": 482000,
    "todaySpent": 74000,
    "targetDailyBudget": 41000,
    "daysRemaining": 13,
    "todayTransactions": [
      { "store": "맥도날드", "amount": 9200 },
      { "store": "올리브영", "amount": 34800 },
      { "store": "배달의민족", "amount": 30000 }
    ]
  }
}
```

### 5.2 Expected AI Response Output Schema
```json
{
  "status": "과소비경고", // "안정" | "주의" | "과소비경고" | "무지출"
  "overspentAmount": 33000,
  "primaryCulprit": "올리브영 및 배달의민족 중복 지출",
  "coachComment": "일일 권장 예산보다 3.3만 원 초과했습니다. 배달과 쇼핑이 겹쳐 지출 속도가 위험합니다.",
  "actionForTomorrow": "내일은 필수 식비 외 무지출을 목표로 2.5만 원 이내로 방어하십시오."
}
```

---

## 6. iOS 환경 제약 사항 및 엔지니어링 고려점

1. **iOS 보안 샌드박스 & 백그라운드 타임아웃**:
   * 타 앱(카카오톡 알림톡 등)의 푸시는 단축어 수신 불가 $ightarrow$ **카드사 'SMS 문자 서비스' 설정 필수**.
   * 단축어 백그라운드 실행 한도 시간은 20~30초 $ightarrow$ 승인 문자 수신 트랙은 LLM 호출 없이 **순수 로컬 연산(0.1초 컷)**으로 즉각 종료.
2. **단축어 무인 실행 설정**:
   * 단축어 편집기에서 `실행 전 묻기 (Ask Before Running): OFF`, `실행 시 알림 (Notify When Run): OFF` 필수 활성화.
3. **iCloud Drive 동기화 경합**:
   * Scriptable의 `FileManager.iCloud()`는 단일 기기 내에서 즉시 캐시/동기화되므로 레이스 컨디션 위험 없음.
4. **무지출(Zero-Spend) 처리**:
   * 22:00 실행 시 당일 트랜잭션이 0건일 경우 Gemini API를 호출하지 않고 `"오늘 무지출 달성! 예산 세이브 완료"` 로컬 알림만 띄워 API 쿼터 절약.

---

## 7. 스크립트 구현 템플릿 (Scriptable)

### 7.1 `parse_sms.js` (Track 1)
```javascript
// Scriptable: parse_sms.js
// 단축어에서 SMS 텍스트를 인자로 전달받아 실행
const rawSMS = args.shortcutParameter || "";

const fm = FileManager.iCloud();
const dir = fm.documentsDirectory();
const configPath = fm.joinPath(dir, "ledger_config.json");

if (!fm.fileExists(configPath)) {
  throw new Error("ledger_config.json 파일이 존재하지 않습니다.");
}
const config = JSON.parse(fm.readString(configPath));

// 1. 범용 SMS 정규식 파싱
const amountMatch = rawSMS.match(/([0-9,]+)\s*원\s*(승인|결제)/i) || rawSMS.match(/(승인|결제)\s*([0-9,]+)\s*원/i);
const storeMatch = rawSMS.match(/(?:사용처|가맹점|상호명)?\s*([가-힣A-Za-z0-9_*·\s]+?)\s*[0-9,]+원/);

const amount = amountMatch ? parseInt((amountMatch[1] || amountMatch[2]).replace(/,/g, ""), 10) : 0;
const store = storeMatch ? storeMatch[1].trim() : "미분류 가맹점";

if (amount === 0) Scriptable.close();

// 2. 월간 장부 파일 로드
const now = new Date();
const yearMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
const ledgerPath = fm.joinPath(dir, `monthly_ledger_${yearMonth}.json`);

let ledger = {
  yearMonth,
  monthlyIncome: config.monthlyIncome,
  totalVariableSpent: 0,
  transactions: []
};
if (fm.fileExists(ledgerPath)) {
  ledger = JSON.parse(fm.readString(ledgerPath));
}

// 3. 정기 구독 매칭 검사
const matchedSub = (config.subscriptions || []).find(sub =>
  store.toUpperCase().includes(sub.matchKeyword.toUpperCase())
);

const isSub = Boolean(matchedSub);
if (!isSub) {
  ledger.totalVariableSpent += amount;
}

ledger.transactions.push({
  id: `tx_${Date.now()}`,
  timestamp: now.toISOString(),
  store,
  amount,
  type: isSub ? "subscription" : "variable",
  isSubscription: isSub,
  subName: isSub ? matchedSub.name : null
});

fm.writeString(ledgerPath, JSON.stringify(ledger, null, 2));

// 4. 로컬 알림 발송
const spendRatio = ((ledger.totalVariableSpent / config.monthlyIncome) * 100).toFixed(1);
const notif = new Notification();
if (isSub) {
  notif.title = `🔄 [정기구독] ${matchedSub.name}`;
  notif.body = `${amount.toLocaleString()}원 결제 (고정비 예산 반영 완료)`;
} else {
  notif.title = `💳 ${amount.toLocaleString()}원 결제 (${store})`;
  notif.body = `변동지출 누적 ${ledger.totalVariableSpent.toLocaleString()}원 (월급의 ${spendRatio}% 소진)`;
}
await notif.schedule();
Scriptable.close();
```

---

## 8. Codex / 개발 에이전트 핸드오프 지침 (Instructions)

Codex 또는 개발 환경에 작업을 지시할 때 다음 순서로 프롬프트를 분할 입력하십시오:

1. **Step 1: SMS 파서 고도화**
   * "다양한 카드사(신한, 현대, 국민, 삼성, 롯데, BC)의 승인 SMS 포맷 10종을 정의하고, 이를 모두 정확하게 파싱하는 견고한 `extractCardTransaction(smsText)` 정규식 파서 함수를 작성해줘."
2. **Step 2: 야간 결산 및 Gemini 연동 스크립트 작성**
   * "본 문서의 5절 API 명세와 JSON 스키마를 준수하여 `daily_audit.js` 스크립트를 작성해줘. fetch API 대신 Scriptable의 `Request` 객체를 사용하고, 당일 무지출 시 조기 리턴 로직을 포함해줘."
3. **Step 3: 홈 화면 위젯 구현**
   * "본 문서의 `monthly_ledger_{YYYYMM}.json`을 파싱하여, 남은 예산 게이지 바와 오늘의 AI 평가 배지('🟢 안정', '🟡 주의', '🔴 경고')를 깔끔하게 보여주는 Scriptable Medium 사이즈 위젯 코드를 작성해줘."
