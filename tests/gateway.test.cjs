const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createGateway, validStats, validResult, validPayload, validReply } = require('../gateway/server.cjs');
const core = require('../shared/ledger-core.js');
const stats = core.summary(core.initial(), 'daily', '2026-09-17');
const content = { status: 'stable', summary: '기록된 거래가 없습니다.', insights: [], actions: [] };
test('gateway rejects raw personal fields and malformed model responses', () => {
  assert.throws(() => validStats({ ...stats, rawMessage: 'private' }));
  assert.throws(() => validStats({ ...stats, categories: { '개인 가맹점': 100 } }));
  assert.throws(() => validResult({ ...content, actions: 'not array' }));
});
test('batch reports require exact identifiers and individually validated results', () => {
  const payload = validPayload({ reports: [{ id: 'daily-2026-09-17', stats }] });
  assert.deepEqual(validReply({ reports: [{ id: 'daily-2026-09-17', content }] }, payload).reports[0].content, content);
  assert.throws(() => validReply({ reports: [{ id: 'daily-2026-09-18', content }] }, payload));
  assert.throws(() => validPayload({ reports: [payload.reports[0], payload.reports[0]] }));
  assert.throws(() => validReply({ reports: [] }, payload));
});
test('quota misconfiguration fails closed', () => {
  assert.throws(() => createGateway({ stateFile: path.join(os.tmpdir(), 'missing-budget-state-unique.json'), dailyLimit: NaN }));
});
test('authenticated inference, cache, quotas, persistent restart and secret redaction', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-budget-test-'));
  const stateFile = path.join(dir, 'state.json');
  let calls = 0;
  const config = { invitation: 'test-invite', apiKey: 'secret-upstream', dailyLimit: 1, stateFile };
  const server = createGateway(config, async () => { calls++; return content; });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  let base = 'http://127.0.0.1:' + server.address().port;
  const post = (route, body, token = '') => fetch(base + route, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body: JSON.stringify(body) });
  assert.equal((await post('/v1/analyze', { stats })).status, 401);
  assert.equal((await post('/v1/enroll', { invitation: 'wrong' })).status, 403);
  const enrollment = await post('/v1/enroll', { invitation: 'test-invite' }); const { token } = await enrollment.json();
  assert.equal((await post('/v1/analyze', { stats }, token)).status, 200);
  const cached = await (await post('/v1/analyze', { stats }, token)).json(); assert.equal(cached.cached, true); assert.equal(calls, 1);
  assert.equal((await post('/v1/analyze', { stats: { ...stats, spent: 1 } }, token)).status, 429);
  const disk = fs.readFileSync(stateFile, 'utf8'); assert.ok(!disk.includes(token)); assert.ok(!disk.includes('secret-upstream')); assert.ok(!disk.includes('test-invite'));
  await new Promise(resolve => server.close(resolve));
  const restarted = createGateway(config, async () => content);
  await new Promise(resolve => restarted.listen(0, '127.0.0.1', resolve));
  t.after(() => restarted.close()); base = 'http://127.0.0.1:' + restarted.address().port;
  assert.equal((await post('/v1/analyze', { stats: { ...stats, spent: 2 } }, token)).status, 429);
});
test('provider outage returns sanitized error and charges bounded attempt', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-budget-test-'));
  const server = createGateway({ stateFile: path.join(dir, 'state.json'), invitation: 'invite', apiKey: 'secret' }, async () => { throw new Error('secret upstream data'); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const base = 'http://127.0.0.1:' + server.address().port;
  const post = (route, body, token = '') => fetch(base + route, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body: JSON.stringify(body) });
  const { token } = await (await post('/v1/enroll', { invitation: 'invite' })).json();
  const result = await post('/v1/analyze', { stats }, token); assert.equal(result.status, 502);
  assert.deepEqual(await result.json(), { error: 'analysis_unavailable' });
});
test('concurrent inference cannot bypass per-device lock; batch passes through end to end', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-budget-test-'));
  let release, started;
  const entered = new Promise(resolve => { started = resolve; });
  const barrier = new Promise(resolve => { release = resolve; });
  const server = createGateway({ stateFile: path.join(dir, 'state.json'), invitation: 'invite', apiKey: 'secret' }, async payload => {
    started(); await barrier;
    return { reports: payload.reports.map(row => ({ id: row.id, content })) };
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { release(); server.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const base = 'http://127.0.0.1:' + server.address().port;
  const post = (route, body, token = '') => fetch(base + route, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body: JSON.stringify(body) });
  const { token } = await (await post('/v1/enroll', { invitation: 'invite' })).json();
  const payload = { reports: [{ id: 'daily-2026-09-17', stats }] };
  const first = post('/v1/analyze', payload, token); await entered;
  const second = await post('/v1/analyze', payload, token); assert.equal(second.status, 429);
  release(); const response = await first; assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).content.reports[0], { id: 'daily-2026-09-17', content });
});
