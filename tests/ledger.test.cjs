const { test } = require('node:test');
const assert = require('node:assert/strict');
const core = require('../shared/ledger-core.js');
const now = '2026-09-17T13:00:00Z';
function apply(s, op, p) { return core.run(s, op, { now, ...p }); }
function state() { const s = core.initial(); s.settings.expectedSalary = 3500000; s.settings.savingsGoal = 1000000; return s; }
const sms = '[Web발신] 신한카드 승인 6,500원 스타벅스성남 09/17 09:40 누적 482,000원';
test('original spec SMS extracts actual amount and merchant instead of cumulative amount', () => {
  const parsed = core.parseSMS(sms, now);
  assert.equal(parsed.amount, 6500); assert.equal(parsed.store, '스타벅스성남'); assert.equal(parsed.day, '2026-09-17');
});
test('user-selected and custom card issuers control detection', () => {
  const s = state();
  s.settings.cardSources = [{ id: 'local', name: '지역은행 체크카드', keywords: ['지역체크'], enabled: true }];
  apply(s, 'sms', { text: '승인 12,300원 동네마트 09/17 10:10', sourceName: '지역은행 체크카드', id: 'custom' });
  assert.equal(s.transactions[0].card, '지역은행 체크카드');
  assert.equal(s.transactions[0].sourceID, 'local');
  s.settings.cardSources[0].enabled = false;
  apply(s, 'sms', { text: '지역체크 승인 9,000원 식당 09/17 11:10', id: 'disabled' });
  assert.equal(s.pending.length, 1); assert.equal(s.transactions.length, 1);
});
test('SMS duplicate delivery is idempotent', () => {
  const s = state(); apply(s, 'sms', { text: sms, id: 'a' }); apply(s, 'sms', { text: sms, id: 'b' });
  assert.equal(s.transactions.length, 1); assert.equal(core.snapshot(s, '2026-09-17').spent, 6500);
});
test('unknown and foreign currency SMS are preserved pending, never guessed as KRW', () => {
  const s = state(); apply(s, 'sms', { text: '[Web발신] 신한카드 해외승인 USD 20.00 GOOGLE*TEMPORARY', id: 'a' });
  assert.equal(s.pending.length, 1); assert.equal(s.transactions.length, 0);
});
test('exact cancellation links original and restores budget; ambiguous refund stays pending', () => {
  const s = state(); apply(s, 'sms', { text: sms, id: 'a' });
  apply(s, 'sms', { text: sms.replace('승인', '승인취소'), id: 'b' });
  assert.equal(core.snapshot(s, '2026-09-17').spent, 0); assert.equal(s.transactions[1].originalID, 'a');
  apply(s, 'sms', { text: sms.replace('승인', '취소').replace('6,500', '3,000'), id: 'c' });
  assert.equal(s.pending.length, 1); assert.equal(core.snapshot(s, '2026-09-17').spent, 0);
});
test('budget uses reservations once while actual expense remains visible', () => {
  const s = state(); s.settings.plans = [{ id: 'coffee', name: '구독', amount: 6500, day: 17, merchant: '스타벅스성남' }];
  apply(s, 'sms', { text: sms, id: 'a' });
  const snap = core.snapshot(s, '2026-09-17');
  assert.equal(snap.budget, 2493500); assert.equal(snap.remaining, 2493500); assert.equal(snap.spent, 6500);
});
test('broad merchant names do not accidentally classify ordinary shopping as subscriptions', () => {
  const s = state(); s.settings.plans = [{ id: 'coupang', name: '와우', amount: 7890, day: 17, merchant: '쿠팡' }];
  apply(s, 'sms', { text: sms.replace('스타벅스성남', '쿠팡'), id: 'a' });
  assert.equal(s.transactions[0].planID, null);
});
test('salary confirmation replaces forecast and is not double counted', () => {
  const s = state(); assert.equal(core.snapshot(s, '2026-09-17').actualIncome, 0);
  apply(s, 'salary', { amount: 3000000 }); apply(s, 'salary', { amount: 3100000 });
  const snap = core.snapshot(s, '2026-09-17'); assert.equal(snap.actualIncome, 3100000); assert.equal(snap.incomeForBudget, 3100000); assert.equal(s.transactions.length, 1);
});
test('manual extra income increases budget and invalid money is rejected', () => {
  const s = state(); apply(s, 'manual', { id: 'm', kind: 'income', amount: 50000, store: '중고판매', category: '추가수입', day: '2026-09-17' });
  assert.equal(core.snapshot(s, '2026-09-17').incomeForBudget, 3550000);
  assert.throws(() => apply(s, 'manual', { id: 'bad', kind: 'expense', amount: -10, day: '2026-09-17' }));
});
test('KST midnight and yearly/monthly/week-end scheduling', () => {
  assert.equal(core.dateKey('2026-09-16T15:10:00Z'), '2026-09-17');
  const s = state(); s.settings.weekEnd = 4;
  assert.deepEqual(core.due(s, '2026-12-31').map(x => x.type), ['daily', 'weekly', 'monthly', 'yearly']);
  assert.equal(core.summary(s, 'monthly', '2028-02-10').endExclusive, '2028-03-01');
});
test('yearly rollup and monthly previous period compare calendar months', () => {
  const s = state(); for (const [id, day, amount] of [['a', '2026-08-31', 5000], ['b', '2026-09-17', 10000]]) {
    apply(s, 'manual', { id, day, amount, kind: 'expense', store: '식사', category: '식비' });
  }
  assert.equal(core.summary(s, 'monthly', '2026-09-17').previousSpent, 5000);
  const annual = core.summary(s, 'yearly', '2026-12-31'); assert.equal(annual.monthlyTotals.length, 12); assert.equal(annual.spent, 15000);
});
test('report regeneration preserves valid AI but invalidates changed inputs and stale responses', () => {
  const s = state(), first = apply(s, 'report', { type: 'daily' }).value;
  apply(s, 'aiResult', { id: first.id, fingerprint: first.fingerprint, content: { summary: 'AI' }, source: 'test' });
  assert.equal(apply(s, 'report', { type: 'daily' }).value.source, 'test');
  apply(s, 'sms', { text: sms, id: 'a' }); const fresh = apply(s, 'report', { type: 'daily' }).value;
  assert.equal(fresh.source, 'local');
  apply(s, 'aiResult', { id: first.id, fingerprint: first.fingerprint, content: { summary: 'stale' }, source: 'test' });
  assert.equal(s.reports[0].source, 'local');
});
test('resolving pending SMS remains deduplicated', () => {
  const s = state(), text = '신한카드 승인 알 수 없는 양식';
  apply(s, 'sms', { id: 'a', text });
  apply(s, 'manual', { pendingID: 'a', id: 'm', kind: 'expense', amount: 10, day: '2026-09-17', store: '수동', category: '기타' });
  apply(s, 'sms', { id: 'b', text }); assert.equal(s.pending.length, 0); assert.equal(s.transactions.length, 1);
});
test('overrun in one fixed expense is not hidden by another unpaid reservation', () => {
  const s = state(); s.settings.plans = [{ id: 'a', name: '통신', day: 1, amount: 50000 }, { id: 'b', name: '월세', day: 1, amount: 500000 }];
  apply(s, 'manual', { id: 'm', kind: 'expense', amount: 60000, day: '2026-09-17', store: '통신', category: '고정비', planID: 'a' });
  assert.equal(core.snapshot(s, '2026-09-17').remaining, 1940000);
});
test('daily series and category comparison support weekly pattern analysis', () => {
  const s = state();
  for (const [id, day, amount] of [['old', '2026-09-10', 1000], ['today', '2026-09-17', 9000]]) {
    apply(s, 'manual', { id, day, amount, kind: 'expense', store: '식사', category: '식비' });
  }
  const stats = core.summary(s, 'weekly', '2026-09-17');
  assert.equal(stats.dailyTotals.length, 7); assert.equal(stats.dailyTotals[6].spent, 9000);
  assert.equal(stats.previousCategories['식비'], 1000); assert.equal(stats.categories['식비'], 9000);
});
test('new year received delayed December SMS stays in previous year', () => {
  const parsed = core.parseSMS(sms.replace('09/17', '12/31'), '2027-01-01T01:00:00Z');
  assert.equal(parsed.day, '2026-12-31');
});
test('overspent budget exposes debt and clamps daily recommendation to zero', () => {
  const s = state(); s.settings.expectedSalary = 100;
  const snap = core.snapshot(s, '2026-09-17');
  assert.ok(snap.remaining < 0); assert.equal(snap.recommendedDaily, 0); assert.equal(snap.budgetUsage, null);
});
