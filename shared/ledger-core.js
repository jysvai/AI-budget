/* Shared by JavaScriptCore on iOS and Node's test runner. Money is integer KRW. */
(function (root) {
  'use strict';
  const DAY = 86400000;
  function digest(text) {
    if (typeof root.privacyDigest === 'function') return root.privacyDigest(text);
    if (typeof module !== 'undefined' && module.exports) return require('node:crypto').createHash('sha256').update(text).digest('hex');
    throw new Error('개인정보 보호 모듈을 사용할 수 없습니다.');
  }
  // Redact identifiers before persistence, including already partially masked card numbers.
  function redact(value) {
    if (typeof value !== 'string') return value;
    return value
      .replace(/(?:\d[ -]?){13,19}/g, '[카드번호 숨김]')
      .replace(/(?:\d{2,6}[- ]?\*{2,}[- *\d]*|\*{2,}[- *\d]*\d{2,6})/g, '[카드번호 숨김]')
      .replace(/((?:카드(?:번호)?|신한|현대|KB국민|국민|삼성|롯데|하나|우리|비씨|BC|농협)\s*[:：]?\s*)[\[(]?\d{2,8}[\])]?/gi, '$1[카드번호 숨김]')
      .replace(/([\[(])\d{4}([\])])/g, '[카드번호 숨김]')
      .replace(/((?:카드)?(?:끝자리|뒤\s*4자리)\s*[:：]?\s*)\d{4}/g, '$1[숨김]')
      .replace(/(계좌(?:번호)?\s*[:：]?\s*)[\d*-]{5,}/g, '$1[숨김]')
      .replace(/\b01[016789][- ]?\d{3,4}[- ]?\d{4}\b/g, '[전화번호 숨김]')
      .replace(/(CVC|CVV|비밀번호|인증번호|유효기간)\s*[:：]?\s*[\d/*-]+/gi, '$1 [숨김]')
      .replace(/(?:[가-힣*]{2,5})\s*(?:고객님|회원님|님)/g, '[이름 숨김]');
  }
  function redactContent(value) {
    if (typeof value === 'string') return redact(value);
    if (Array.isArray(value)) return value.map(redactContent);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, redactContent(v)]));
    return value;
  }
  function migratePrivacy(state) {
    validate(state);
    if (!Array.isArray(state.settings.cardSources)) state.settings.cardSources = defaultCardSources();
    for (const row of [...state.transactions, ...state.pending]) {
      if (row.fingerprint && !/^sha256:[0-9a-f]{64}$/.test(row.fingerprint)) row.fingerprint = 'sha256:' + digest(row.fingerprint);
      for (const field of ['text', 'rawMessage', 'store', 'reason', 'card']) if (row[field]) row[field] = redact(row[field]);
      delete row.rawMessage;
      if (row.kind === 'refund' && !row.eventType) row.eventType = 'refund';
      if (row.kind === 'expense' && !row.eventType) row.eventType = 'approval';
    }
    state.settings.plans.forEach(p => { p.name = redact(p.name); p.merchant = redact(p.merchant); });
    if (state.settings.aiMode === 'default') state.settings.aiMode = 'local';
    // Old report text may contain merchant text copied by earlier builds. Regenerate from aggregates.
    if (state.privacyVersion !== 1) state.reports = [];
    state.reports.forEach(report => { report.content = redactContent(report.content); });
    state.privacyVersion = 1;
    return state;
  }
  function assert(ok, message) { if (!ok) throw new Error(message); }
  function money(value) {
    assert(Number.isSafeInteger(value) && value >= 0 && value <= 1e12, '금액은 0 이상의 정수 원으로 입력하세요.');
    return value;
  }
  function dateKey(time) { return new Date(new Date(time).getTime() + 9 * 3600000).toISOString().slice(0, 10); }
  function shift(key, days) { return new Date(Date.parse(key + 'T00:00:00Z') + days * DAY).toISOString().slice(0, 10); }
  function monthDays(key) { return new Date(Date.UTC(+key.slice(0, 4), +key.slice(5, 7), 0)).getUTCDate(); }
  function defaultCardSources() {
    return [
      ['shinhan', '신한카드', ['신한카드', '신한']], ['hyundai', '현대카드', ['현대카드']],
      ['kb', 'KB국민카드', ['KB국민카드', '국민카드', 'KB카드']], ['samsung', '삼성카드', ['삼성카드']],
      ['lotte', '롯데카드', ['롯데카드']], ['hana', '하나카드', ['하나카드']],
      ['woori', '우리카드', ['우리카드']], ['bc', 'BC카드', ['BC카드', '비씨카드']],
      ['nh', 'NH농협카드', ['NH농협카드', '농협카드']], ['ibk', 'IBK카드', ['IBK카드', '기업BC']],
      ['kakao', '카카오뱅크카드', ['카카오뱅크', '카뱅카드']], ['kbank', '케이뱅크카드', ['케이뱅크']],
      ['toss', '토스뱅크카드', ['토스뱅크']]
    ].map(([id, name, keywords]) => ({ id, name, keywords, enabled: true }));
  }
  function initial() {
    return { version: 2, privacyVersion: 1, settings: { expectedSalary: 0, savingsGoal: 0, salaryDay: 25, reminderHour: 20,
      auditHour: 22, weekEnd: 0, aiMode: 'local', provider: 'groq', model: '', consent: false, setupDone: false,
      smsGuideDone: false, auditGuideDone: false, widgetGuideDone: false, plans: [], cardSources: defaultCardSources() },
      transactions: [], pending: [], reports: [], salaries: {}, lastSMS: null, lastAudit: null };
  }
  function validate(state) {
    assert(state && state.version === 2 && Array.isArray(state.transactions) && Array.isArray(state.pending)
      && Array.isArray(state.reports) && state.settings && state.salaries, '장부 형식을 확인할 수 없습니다.');
    return state;
  }
  function bounds(type, day) {
    let start = day, end = shift(day, 1);
    if (type === 'weekly') start = shift(day, -6);
    else if (type === 'monthly') { start = day.slice(0, 7) + '-01'; end = shift(start, monthDays(day)); }
    else if (type === 'yearly') { start = day.slice(0, 4) + '-01-01'; end = (+day.slice(0, 4) + 1) + '-01-01'; }
    else assert(type === 'daily', '지원하지 않는 결산 주기입니다.');
    return { start, end };
  }
  function sum(rows) { return rows.reduce((n, t) => n + (t.kind === 'refund' ? -t.amount : t.amount), 0); }
  function credited(state, transaction) {
    return state.transactions.filter(t => t.kind === 'refund' && t.originalID === transaction.id).reduce((n, t) => n + t.amount, 0);
  }
  function summary(state, type, day) {
    const range = bounds(type, day);
    const rows = state.transactions.filter(t => t.day >= range.start && t.day < range.end);
    const expenses = rows.filter(t => t.kind !== 'income');
    const length = (Date.parse(range.end) - Date.parse(range.start)) / DAY;
    let previous = { start: shift(range.start, -length), end: range.start };
    if (type === 'monthly') previous = bounds('monthly', shift(range.start, -1));
    if (type === 'yearly') previous = bounds('yearly', shift(range.start, -1));
    const prior = state.transactions.filter(t => t.day >= previous.start && t.day < previous.end && t.kind !== 'income');
    const categories = {};
    expenses.forEach(t => { categories[t.category] = (categories[t.category] || 0) + (t.kind === 'refund' ? -t.amount : t.amount); });
    const previousCategories = {};
    prior.forEach(t => { previousCategories[t.category] = (previousCategories[t.category] || 0) + (t.kind === 'refund' ? -t.amount : t.amount); });
    const dailyTotals = [];
    if (type !== 'yearly') for (let i = 0; i < length; i++) {
      const date = shift(range.start, i), dayRows = rows.filter(t => t.day === date);
      if (date > day) break;
      dailyTotals.push({ day: date, income: sum(dayRows.filter(t => t.kind === 'income')),
        spent: sum(dayRows.filter(t => t.kind !== 'income')), count: dayRows.length });
    }
    const monthlyTotals = [];
    if (type === 'yearly') for (let m = 1; m <= 12; m++) {
      const prefix = day.slice(0, 4) + '-' + String(m).padStart(2, '0');
      const monthRows = rows.filter(t => t.day.startsWith(prefix));
      monthlyTotals.push({ month: prefix, income: sum(monthRows.filter(t => t.kind === 'income')), spent: sum(monthRows.filter(t => t.kind !== 'income')) });
    }
    return { periodType: type, start: range.start, endExclusive: range.end,
      income: sum(rows.filter(t => t.kind === 'income')), spent: sum(expenses), previousSpent: sum(prior),
      grossSpent: expenses.filter(t => t.kind === 'expense').reduce((n, t) => n + t.amount, 0),
      cancellationTotal: expenses.filter(t => t.eventType === 'cancellation').reduce((n, t) => n + t.amount, 0),
      refundTotal: expenses.filter(t => t.kind === 'refund' && t.eventType !== 'cancellation').reduce((n, t) => n + t.amount, 0),
      transactionCount: rows.length, categories, previousCategories, dailyTotals, monthlyTotals,
      pendingCount: state.pending.length, coverage: 'recorded-transactions-only',
      budget: { expectedSalary: state.settings.expectedSalary, savingsGoal: state.settings.savingsGoal,
        fixedReservation: state.settings.plans.reduce((n, p) => n + p.amount, 0) } };
  }
  function snapshot(state, day) {
    const month = day.slice(0, 7);
    const data = summary(state, 'monthly', day);
    const rows = state.transactions.filter(t => t.day.startsWith(month));
    const salary = state.salaries[month];
    const extraIncome = sum(rows.filter(t => t.kind === 'income' && t.origin !== 'salary'));
    const incomeForBudget = (salary === undefined ? state.settings.expectedSalary : salary) + extraIncome;
    const reserved = state.settings.plans.reduce((n, p) => n + p.amount, 0);
    const plannedActual = sum(rows.filter(t => t.kind !== 'income' && t.planID));
    const variableSpent = sum(rows.filter(t => t.kind !== 'income' && !t.planID));
    // Plan-level overspend must not be masked by a different unpaid reservation.
    const overrun = state.settings.plans.reduce((n, p) => n + Math.max(0,
      sum(rows.filter(t => t.kind !== 'income' && t.planID === p.id)) - p.amount), 0);
    const budget = incomeForBudget - reserved - state.settings.savingsGoal;
    const remaining = budget - variableSpent - overrun;
    return { month, incomeForBudget, actualIncome: data.income, salaryConfirmed: salary !== undefined,
      reserved, plannedActual, spent: data.spent, grossSpent: data.grossSpent, cancellationTotal: data.cancellationTotal,
      refundTotal: data.refundTotal, variableSpent, budget, remaining,
      recommendedDaily: Math.max(0, Math.floor(remaining / (monthDays(day) - +day.slice(8) + 1))),
      spendingRate: data.income > 0 ? data.spent / data.income : null,
      budgetUsage: budget > 0 ? (variableSpent + overrun) / budget : null,
      pendingCount: state.pending.length, lastSMS: state.lastSMS, lastAudit: state.lastAudit };
  }
  function localReport(stats) {
    const change = stats.spent - stats.previousSpent;
    return { status: stats.pendingCount ? 'review' : change > 0 ? 'attention' : 'stable',
      summary: '기록된 지출 ' + stats.spent.toLocaleString('ko-KR') + '원 · 이전 기간 대비 ' + change.toLocaleString('ko-KR') + '원',
      insights: Object.keys(stats.categories).sort((a, b) => stats.categories[b] - stats.categories[a]).slice(0, 3)
        .map(k => k + ' ' + stats.categories[k].toLocaleString('ko-KR') + '원'),
      actions: [stats.pendingCount ? '검토함에 보관된 거래를 확인하면 분석이 정확해집니다.' : 'SMS에 없는 현금·이체 거래가 있으면 추가해주세요.'] };
  }
  function parseSMS(text, received, configuredSources, sourceName) {
    assert(typeof text === 'string' && text.length > 0 && text.length < 10000, '문자 본문이 비어 있거나 너무 깁니다.');
    const normalized = text.replace(/\s+/g, ' ').trim();
    const label = typeof sourceName === 'string' ? sourceName.replace(/\s+/g, ' ').trim() : '';
    const sources = (Array.isArray(configuredSources) ? configuredSources : defaultCardSources()).filter(x => x && x.enabled !== false);
    const source = sources.find(x => [x.name, ...(Array.isArray(x.keywords) ? x.keywords : [])]
      .some(keyword => typeof keyword === 'string' && keyword.trim() &&
        (normalized.toLocaleUpperCase('ko-KR').includes(keyword.trim().toLocaleUpperCase('ko-KR')) ||
         label.toLocaleUpperCase('ko-KR').includes(keyword.trim().toLocaleUpperCase('ko-KR')))));
    const card = source ? source.name : null;
    const kind = /취소|환불/.test(normalized) ? 'refund' : 'expense';
    if (!card || !/승인|결제|취소|환불/.test(normalized)) return { reason: '지원 문자 형식 확인 필요' };
    if (/USD|EUR|JPY|해외|거절|실패|예정/.test(normalized)) return { reason: '해외·미확정 또는 승인 이외 문자' };
    const amountPart = normalized.split(/누적|잔액|이용한도/)[0];
    const amounts = [...amountPart.matchAll(/([\d,]+)\s*원/g)];
    if (amounts.length !== 1) return { reason: '승인 금액을 확정할 수 없음' };
    const amount = Number(amounts[0][1].replace(/,/g, ''));
    if (!Number.isSafeInteger(amount) || amount <= 0 || amount > 1e12) return { reason: '유효하지 않은 금액' };
    let day = dateKey(received);
    const stamp = normalized.match(/(\d{2})\/(\d{2})\s+(\d{2}):(\d{2})/);
    if (stamp) {
      let year = +day.slice(0, 4);
      const candidate = year + '-' + stamp[1] + '-' + stamp[2];
      if (Date.parse(candidate) - Date.parse(day) > 180 * DAY) year--;
      day = year + '-' + stamp[1] + '-' + stamp[2];
      if (Number.isNaN(Date.parse(day)) || new Date(day).toISOString().slice(0, 10) !== day || +stamp[3] > 23 || +stamp[4] > 59)
        return { reason: '거래 날짜 확인 필요' };
    }
    const after = amountPart.slice(amounts[0].index + amounts[0][0].length)
      .replace(/\d{2}\/\d{2}\s+\d{2}:\d{2}/g, '').replace(/^(승인|결제|취소|환불)\s*/, '').trim();
    // Conservative first format: issuer ... amount ... merchant [date time]. Other layouts go to review.
    if (!after || /일시불|할부|본인|\*{2}/.test(after)) return { reason: '가맹점 위치 확인 필요' };
    const cardIdentifier = (normalized.match(/(?:카드(?:번호)?\s*[:：]?\s*|[\[(])([\d* -]{4,23})(?:[\])]|\s|$)/i) || [])[1];
    return { amount, store: redact(after.slice(0, 100)), day, kind, card, sourceID: source.id,
      eventType: /환불/.test(normalized) ? 'refund' : /취소/.test(normalized) ? 'cancellation' : 'approval',
      cardToken: cardIdentifier ? digest(card + '|' + cardIdentifier.trim()) : null,
      fingerprint: 'sha256:' + digest(day + '|' + source.id + '|' + normalized) };
  }
  function run(state, op, p) {
    migratePrivacy(state);
    const day = dateKey(p.now || new Date().toISOString());
    let value = null;
    if (op === 'settings') {
      const s = p.settings;
      money(s.expectedSalary); money(s.savingsGoal);
      assert(Number.isInteger(s.salaryDay) && s.salaryDay >= 1 && s.salaryDay <= 31, '월급일 범위 오류');
      for (const field of ['reminderHour', 'auditHour']) assert(Number.isInteger(s[field]) && s[field] >= 0 && s[field] < 24, '시간 범위 오류');
      assert(Number.isInteger(s.weekEnd) && s.weekEnd >= 0 && s.weekEnd <= 6, '요일 범위 오류');
      assert(['local', 'personal'].includes(s.aiMode), 'AI 모드 오류');
      assert(Array.isArray(s.plans) && s.plans.length <= 100, '고정비 목록 오류');
      assert(Array.isArray(s.cardSources) && s.cardSources.length <= 50, '카드사 목록 오류');
      s.plans.forEach(plan => { money(plan.amount); assert(plan.id && plan.name && plan.day >= 1 && plan.day <= 31, '고정비 입력 오류'); });
      assert(new Set(s.plans.map(x => x.id)).size === s.plans.length, '고정비 ID 중복');
      s.plans.forEach(plan => { plan.name = redact(plan.name); plan.merchant = redact(plan.merchant); });
      s.cardSources.forEach(source => {
        assert(source.id && typeof source.name === 'string' && source.name.trim() && typeof source.enabled === 'boolean', '카드사 입력 오류');
        assert(Array.isArray(source.keywords) && source.keywords.length > 0 && source.keywords.length <= 20
          && source.keywords.every(x => typeof x === 'string' && x.trim() && x.length <= 50), '카드사 감지어 오류');
        source.name = redact(source.name.trim()); source.keywords = source.keywords.map(x => redact(x.trim()));
      });
      assert(new Set(s.cardSources.map(x => x.id)).size === s.cardSources.length, '카드사 ID 중복');
      state.settings = s;
    } else if (op === 'salary') {
      const amount = money(p.amount), month = day.slice(0, 7);
      state.salaries[month] = amount;
      state.transactions = state.transactions.filter(t => t.id !== 'salary-' + month);
      state.transactions.push({ id: 'salary-' + month, kind: 'income', amount, store: '월급', category: '월급', day, origin: 'salary', planID: null });
    } else if (op === 'manual') {
      assert(['expense', 'income', 'refund'].includes(p.kind), '거래 종류 오류'); money(p.amount);
      assert(p.amount > 0 && p.id && !state.transactions.some(t => t.id === p.id), '금액 또는 거래 ID 오류');
      assert(/^\d{4}-\d{2}-\d{2}$/.test(p.day) && !Number.isNaN(Date.parse(p.day)) && new Date(p.day).toISOString().slice(0, 10) === p.day, '날짜 오류');
      assert(p.store && p.store.length <= 100 && p.category && p.category.length <= 30, '내용과 분류를 입력하세요.');
      assert(['기타', '식비', '카페', '쇼핑', '교통', '주거', '의료', '문화', '고정비', '추가수입', '미분류', '월급'].includes(p.category), '지원하지 않는 분류');
      assert(!p.planID || state.settings.plans.some(x => x.id === p.planID), '고정비 연결 오류');
      if (p.pendingID) assert(state.pending.some(x => x.id === p.pendingID), '검토 항목이 이미 처리되었습니다.');
      const pending = state.pending.find(x => x.id === p.pendingID);
      let original = null;
      if (p.kind === 'refund' && p.originalID) {
        original = state.transactions.find(t => t.id === p.originalID && t.kind === 'expense');
        assert(original && p.amount <= original.amount - credited(state, original), '원거래 잔액보다 취소/환불액이 큽니다.');
      }
      state.transactions.push({ id: p.id, kind: p.kind, amount: p.amount, store: redact(p.store), category: original ? original.category : p.category,
        day: p.day, planID: original ? original.planID : p.kind === 'income' ? null : p.planID || null,
        eventType: p.kind === 'refund' ? (p.eventType === 'cancellation' ? 'cancellation' : 'refund') : p.kind === 'income' ? 'income' : 'approval',
        originalID: original ? original.id : null, partial: original ? p.amount < original.amount : false,
        card: p.card ? redact(p.card) : null,
        origin: ['wallet', 'shortcut'].includes(p.origin) ? p.origin : 'manual', fingerprint: pending ? pending.fingerprint : null });
      state.pending = state.pending.filter(x => x.id !== p.pendingID);
    } else if (op === 'sms') {
      const parsed = parseSMS(p.text, p.now, state.settings.cardSources, p.sourceName);
      const fingerprint = parsed.fingerprint || 'sha256:' + digest(day + '|' + (p.sourceName || '') + '|' + p.text.replace(/\s+/g, ' ').trim());
      state.lastSMS = p.now;
      if (state.transactions.some(t => t.fingerprint === fingerprint) || state.pending.some(t => t.fingerprint === fingerprint)) value = '중복 문자를 건너뛰었습니다.';
      else {
        let reason = parsed.reason, original = null;
        if (!reason && parsed.kind === 'refund') {
          const candidates = state.transactions.filter(t => t.kind === 'expense' && t.card === parsed.card && t.store === parsed.store
            && (parsed.cardToken ? t.cardToken === parsed.cardToken : !t.cardToken)
            && parsed.amount <= t.amount - credited(state, t) && t.day <= parsed.day && t.day >= shift(parsed.day, -90));
          if (candidates.length === 1) original = candidates[0];
          else reason = '취소/환불 원거래 확인 필요';
        }
        if (reason) {
          state.pending.push({ id: p.id, text: redact(p.text), received: p.now, reason, fingerprint,
            eventType: parsed.eventType || (/환불/.test(p.text) ? 'refund' : /취소/.test(p.text) ? 'cancellation' : 'approval') });
          value = '검토함에 보관했습니다: ' + reason;
        } else {
          const plans = state.settings.plans.filter(plan => plan.merchant && plan.merchant.toUpperCase() === parsed.store.toUpperCase()
            && plan.amount === parsed.amount && Math.abs(Math.min(plan.day, monthDays(parsed.day)) - +parsed.day.slice(8)) <= 3
            && !state.transactions.some(t => t.planID === plan.id && t.kind === 'expense' && t.day.slice(0, 7) === parsed.day.slice(0, 7)));
          const plan = plans.length === 1 ? plans[0] : null;
          const origin = ['sms', 'email', 'wallet', 'screenshot', 'shortcut'].includes(p.origin) ? p.origin : 'sms';
          state.transactions.push({ ...parsed, id: p.id, origin, planID: original ? original.planID : plan ? plan.id : null,
            category: original ? original.category : plan ? '고정비' : '미분류', originalID: original ? original.id : null,
            partial: original ? parsed.amount < original.amount : false });
          value = parsed.store + ' ' + parsed.amount.toLocaleString('ko-KR') + '원 ' +
            (parsed.eventType === 'cancellation' ? '취소 기록' : parsed.eventType === 'refund' ? '환불 기록' : '승인 기록');
        }
      }
    } else if (op === 'report') {
      const stats = summary(state, p.type, p.day || day), id = p.type + '-' + stats.start;
      const prior = state.reports.find(x => x.id === id);
      const fingerprint = JSON.stringify(stats);
      const unchanged = prior && prior.fingerprint === fingerprint;
      const report = { id, type: p.type, start: stats.start, end: stats.endExclusive, created: p.now,
        fingerprint, stats, content: unchanged ? prior.content : localReport(stats), source: unchanged ? prior.source : 'local' };
      state.reports = state.reports.filter(x => x.id !== id); state.reports.push(report); state.lastAudit = p.now;
      value = report;
    } else if (op === 'aiResult') {
      const report = state.reports.find(x => x.id === p.id);
      assert(report, '결산을 찾을 수 없습니다.');
      if (report.fingerprint === p.fingerprint) { report.content = redactContent(p.content); report.source = p.source; }
    } else if (op === 'deleteTransaction') {
      const tx = state.transactions.find(t => t.id === p.id);
      assert(tx && tx.origin === 'manual', '수동 거래만 삭제할 수 있습니다.');
      assert(!state.transactions.some(t => t.originalID === p.id), '취소/환불이 연결된 원거래는 삭제할 수 없습니다.');
      state.transactions = state.transactions.filter(t => t.id !== p.id);
    } else assert(op === 'snapshot', '알 수 없는 작업');
    return { state, value, snapshot: snapshot(state, day) };
  }
  function due(state, day) {
    const periods = [{ type: 'daily', day }];
    if (new Date(day + 'T00:00:00Z').getUTCDay() === state.settings.weekEnd) periods.push({ type: 'weekly', day });
    if (+day.slice(8) === monthDays(day)) periods.push({ type: 'monthly', day });
    if (day.slice(5) === '12-31') periods.push({ type: 'yearly', day });
    return periods;
  }
  const api = { initial, run, snapshot, summary, parseSMS, due, dateKey, validate, redact, migratePrivacy, defaultCardSources,
    bridge: function (stateJSON, op, payloadJSON) { return JSON.stringify(run(JSON.parse(stateJSON), op, JSON.parse(payloadJSON))); } };
  root.LedgerCore = api;
  if (typeof module !== 'undefined') module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
