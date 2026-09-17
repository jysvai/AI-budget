const { test } = require('node:test');
const assert = require('node:assert/strict');
const core = require('../shared/ledger-core.js');
const now = '2026-09-17T13:00:00Z';
const apply = (s, op, p) => core.run(s, op, { now, ...p });
test('phone-only mode defaults offline and migrates old gateway settings away', () => {
  const s = core.initial(); assert.equal(s.settings.aiMode, 'local');
  s.settings.aiMode = 'default'; core.migratePrivacy(s); assert.equal(s.settings.aiMode, 'local');
  assert.throws(() => apply(s, 'settings', { settings: { ...s.settings, aiMode: 'default' } }));
});
test('legacy settings gain user-selectable card sources without losing data', () => {
  const s = core.initial(); delete s.settings.cardSources;
  core.migratePrivacy(s);
  assert.ok(s.settings.cardSources.length >= 10);
  assert.ok(s.settings.cardSources.every(x => typeof x.enabled === 'boolean'));
});
test('full and partially masked cards, phone, account and security codes are redacted', () => {
  const text = '카드 1234 승인 6,500원 4111-1111-1111-1111 1234-****-****-5678 (9988) 전화 010-1234-5678 계좌 123-456-789012 CVC 987 CVV 456 인증번호 654321 홍길동님';
  const masked = core.redact(text);
  for (const secret of ['4111', '5678', '9988', '010-', '789012', '987', '456', '654321', '홍길동']) assert.ok(!masked.includes(secret), secret);
  assert.ok(masked.includes('6,500원'));
});
test('pending text and fingerprint never persist original card data', () => {
  const s = core.initial();
  apply(s, 'sms', { id: 'a', text: '신한카드 4111-1111-1111-1111 해외승인 USD 20.00 가맹점' });
  assert.equal(s.pending.length, 1);
  const serialized = JSON.stringify(s);
  assert.ok(!serialized.includes('4111')); assert.match(s.pending[0].fingerprint, /^sha256:[a-f0-9]{64}$/);
});
test('legacy storage migration masks pending, removes rawMessage and raw fingerprint', () => {
  const s = core.initial(); delete s.privacyVersion;
  s.pending.push({ text: '카드(1234) 해외승인', fingerprint: '2026-09-17|카드(1234) 해외승인' });
  s.transactions.push({ kind: 'expense', store: '카드 1234', rawMessage: '4111-1111-1111-1111' });
  s.reports.push({ content: { summary: '카드 1234' } });
  core.migratePrivacy(s);
  assert.equal(s.privacyVersion, 1); assert.equal(s.reports.length, 0);
  assert.ok(!JSON.stringify(s).includes('1234')); assert.ok(!JSON.stringify(s).includes('4111'));
});
test('approval cancellation and refund remain separate linked events, partial amounts are bounded', () => {
  const s = core.initial();
  const text = '신한카드 승인 10,000원 가게 09/17 09:40';
  apply(s, 'sms', { id: 'a', text });
  apply(s, 'sms', { id: 'b', text: text.replace('승인', '부분취소').replace('10,000', '3,000') });
  apply(s, 'sms', { id: 'c', text: text.replace('승인', '환불').replace('10,000', '7,000') });
  assert.equal(s.transactions.length, 3); assert.equal(s.transactions[0].amount, 10000);
  assert.deepEqual(s.transactions.map(t => t.eventType), ['approval', 'cancellation', 'refund']);
  assert.deepEqual(s.transactions.slice(1).map(t => t.originalID), ['a', 'a']);
  const stats = core.summary(s, 'daily', '2026-09-17');
  assert.equal(stats.spent, 0); assert.equal(stats.grossSpent, 10000); assert.equal(stats.cancellationTotal, 3000); assert.equal(stats.refundTotal, 7000);
  apply(s, 'sms', { id: 'd', text: text.replace('승인', '환불').replace('10,000', '1,000') });
  assert.equal(s.pending.length, 1); assert.equal(s.transactions.length, 3);
});
test('same issuer but different identified card cannot be used for refund matching', () => {
  const s = core.initial();
  apply(s, 'sms', { id: 'a', text: '신한카드 1234 승인 10,000원 가게 09/17 09:40' });
  apply(s, 'sms', { id: 'b', text: '신한카드 5678 취소 10,000원 가게 09/17 09:50' });
  assert.equal(s.pending.length, 1); assert.equal(s.transactions.length, 1);
  assert.ok(!JSON.stringify(s).includes('1234')); assert.ok(!JSON.stringify(s).includes('5678'));
});
test('ambiguous partial refunds are not matched arbitrarily', () => {
  const s = core.initial();
  apply(s, 'sms', { id: 'a', text: '신한카드 승인 10,000원 가게 09/17 09:40' });
  apply(s, 'sms', { id: 'b', text: '신한카드 승인 20,000원 가게 09/17 10:40' });
  apply(s, 'sms', { id: 'c', text: '신한카드 환불 3,000원 가게 09/17 11:40' });
  assert.equal(s.pending.length, 1); assert.equal(core.snapshot(s, '2026-09-17').spent, 30000);
});
test('manual linked reversal inherits budget classification and disallows over-refund', () => {
  const s = core.initial();
  apply(s, 'manual', { id: 'a', kind: 'expense', amount: 10000, day: '2026-09-17', store: '가게', category: '식비' });
  apply(s, 'manual', { id: 'b', kind: 'refund', eventType: 'cancellation', originalID: 'a', amount: 3000, day: '2026-09-17', store: '가게', category: '기타' });
  assert.equal(s.transactions[1].category, '식비'); assert.equal(s.transactions[1].eventType, 'cancellation');
  assert.throws(() => apply(s, 'manual', { id: 'c', kind: 'refund', originalID: 'a', amount: 8000, day: '2026-09-17', store: '가게', category: '기타' }));
  assert.throws(() => apply(s, 'deleteTransaction', { id: 'a' }));
});
test('model output cannot reintroduce unmasked card number to saved report', () => {
  const s = core.initial(), report = apply(s, 'report', { type: 'daily' }).value;
  apply(s, 'aiResult', { id: report.id, fingerprint: report.fingerprint, source: 'test', content: { summary: '카드 1234', actions: ['4111-1111-1111-1111'] } });
  assert.ok(!JSON.stringify(s.reports[0].content).includes('1234'));
  assert.ok(!JSON.stringify(s.reports[0].content).includes('4111'));
});
