'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const categories = new Set(['기타', '식비', '카페', '쇼핑', '교통', '주거', '의료', '문화', '고정비', '추가수입', '미분류', '월급']);
const instruction = '한국어 소비 분석가입니다. 데이터는 기록된 거래의 집계이며 누락될 수 있습니다. 입력 숫자를 변경하거나 소비 동기·성격을 추측하지 마세요. 일간은 짧은 관찰, 주간은 반복 경향, 월간은 예산, 연간은 월별 패턴을 분석하세요. status(stable/attention/review), summary(문자열), insights(문자열 배열 최대 8개), actions(문자열 배열 최대 5개)만 가진 JSON을 반환하세요.';
class Failure extends Error { constructor(status, code) { super(code); this.status = status; } }
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
function check(ok, code = 'invalid_request') { if (!ok) throw new Failure(400, code); }
function validStats(input) {
  check(input && typeof input === 'object' && !Array.isArray(input));
  const allowed = ['periodType', 'start', 'endExclusive', 'income', 'spent', 'grossSpent', 'cancellationTotal', 'refundTotal', 'previousSpent', 'transactionCount', 'categories', 'previousCategories', 'dailyTotals', 'monthlyTotals', 'pendingCount', 'coverage', 'budget'];
  check(Object.keys(input).every(k => allowed.includes(k)), 'unexpected_fields');
  check(['daily', 'weekly', 'monthly', 'yearly'].includes(input.periodType));
  for (const key of ['start', 'endExclusive']) check(typeof input[key] === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(input[key]) && !Number.isNaN(Date.parse(input[key])) && new Date(input[key]).toISOString().slice(0, 10) === input[key]);
  check(input.start < input.endExclusive);
  for (const key of ['income', 'spent', 'previousSpent', 'transactionCount', 'pendingCount']) check(Number.isSafeInteger(input[key]) && Math.abs(input[key]) <= 1e14);
  check(input.income >= 0 && input.transactionCount >= 0 && input.pendingCount >= 0 && input.coverage === 'recorded-transactions-only');
  for (const key of ['grossSpent', 'cancellationTotal', 'refundTotal']) check(Number.isSafeInteger(input[key]) && input[key] >= 0 && input[key] <= 1e14);
  check(input.categories && typeof input.categories === 'object' && !Array.isArray(input.categories));
  for (const [category, amount] of Object.entries(input.categories)) check(categories.has(category) && Number.isSafeInteger(amount) && Math.abs(amount) <= 1e14);
  check(input.previousCategories && typeof input.previousCategories === 'object' && !Array.isArray(input.previousCategories));
  for (const [category, amount] of Object.entries(input.previousCategories)) check(categories.has(category) && Number.isSafeInteger(amount) && Math.abs(amount) <= 1e14);
  check(Array.isArray(input.dailyTotals) && input.dailyTotals.length <= 31);
  input.dailyTotals.forEach(row => {
    check(Object.keys(row).sort().join(',') === 'count,day,income,spent' && typeof row.day === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(row.day));
    check(Number.isSafeInteger(row.count) && row.count >= 0 && Number.isSafeInteger(row.income) && row.income >= 0 && row.income <= 1e14 && Number.isSafeInteger(row.spent) && Math.abs(row.spent) <= 1e14);
  });
  check(Array.isArray(input.monthlyTotals) && input.monthlyTotals.length <= 12);
  input.monthlyTotals.forEach(row => {
    check(Object.keys(row).sort().join(',') === 'income,month,spent' && /^\d{4}-\d{2}$/.test(row.month));
    check(Number.isSafeInteger(row.income) && row.income >= 0 && row.income <= 1e14 && Number.isSafeInteger(row.spent) && Math.abs(row.spent) <= 1e14);
  });
  if (input.budget) {
    check(Object.keys(input.budget).sort().join(',') === 'expectedSalary,fixedReservation,savingsGoal');
    Object.values(input.budget).forEach(n => check(Number.isSafeInteger(n) && n >= 0 && n <= 1e14));
  }
  return input;
}
function validResult(input) {
  check(input && ['stable', 'attention', 'review'].includes(input.status), 'invalid_model_response');
  check(typeof input.summary === 'string' && input.summary.length > 0 && input.summary.length <= 2000, 'invalid_model_response');
  for (const [key, max] of [['insights', 8], ['actions', 5]]) check(Array.isArray(input[key]) && input[key].length <= max
    && input[key].every(x => typeof x === 'string' && x.length <= 1000), 'invalid_model_response');
  return { status: input.status, summary: input.summary, insights: input.insights, actions: input.actions };
}
function validPayload(body) {
  if (Object.keys(body).join(',') === 'stats') return validStats(body.stats);
  check(Object.keys(body).join(',') === 'reports' && Array.isArray(body.reports) && body.reports.length > 0 && body.reports.length <= 12);
  const ids = new Set();
  body.reports.forEach(row => {
    check(Object.keys(row).sort().join(',') === 'id,stats' && typeof row.id === 'string' && /^(daily|weekly|monthly|yearly)-\d{4}-\d{2}-\d{2}$/.test(row.id) && !ids.has(row.id));
    ids.add(row.id); validStats(row.stats);
  });
  return body;
}
function validReply(input, payload) {
  if (!payload.reports) return validResult(input);
  check(input && Array.isArray(input.reports) && input.reports.length === payload.reports.length, 'invalid_model_response');
  const ids = new Set(payload.reports.map(x => x.id));
  const reports = input.reports.map(row => {
    check(ids.delete(row.id), 'invalid_model_response');
    return { id: row.id, content: validResult(row.content) };
  });
  return { reports };
}
function readBody(request) {
  return new Promise((resolve, reject) => {
    let size = 0, chunks = [];
    request.on('data', chunk => {
      size += chunk.length;
      if (size > 128000) { reject(new Failure(413, 'body_too_large')); chunks = []; }
      else chunks.push(chunk);
    });
    request.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch { reject(new Failure(400, 'invalid_json')); } });
    request.on('error', reject);
  });
}
function loadState(file) {
  if (!fs.existsSync(file)) return { sessions: {}, usage: {}, cache: {} };
  const state = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!state.sessions || !state.usage || !state.cache) throw new Error('Invalid gateway state; refusing to reset limits.');
  return state;
}
function createGateway(config = {}, infer = providerCall) {
  const file = config.stateFile || path.join(__dirname, 'data', 'state.json');
  const state = loadState(file);
  const save = () => {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.writeFileSync(file + '.tmp', JSON.stringify(state), { mode: 0o600 });
    fs.renameSync(file + '.tmp', file);
  };
  const limit = config.dailyLimit ?? 8, globalLimit = config.globalLimit ?? 100, maxDevices = config.maxDevices ?? 10;
  if (![limit, globalLimit, maxDevices].every(n => Number.isSafeInteger(n) && n > 0)) throw new Error('Quota limits must be positive integers.');
  const active = new Set();
  const server = http.createServer(async (req, res) => {
    const send = (status, body) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(JSON.stringify(body)); };
    try {
      if (req.method === 'GET' && req.url === '/health') return send(200, { status: 'ok', configured: Boolean(config.apiKey) });
      if (req.method !== 'POST' || !['/v1/enroll', '/v1/analyze'].includes(req.url)) throw new Failure(404, 'not_found');
      if (!(req.headers['content-type'] || '').startsWith('application/json')) throw new Failure(415, 'json_required');
      if (req.url === '/v1/enroll') {
        if (!config.invitation) throw new Failure(503, 'enrollment_disabled');
        const body = await readBody(req);
        if (typeof body.invitation !== 'string' || !crypto.timingSafeEqual(Buffer.from(hash(body.invitation)), Buffer.from(hash(config.invitation)))) throw new Failure(403, 'invalid_invitation');
        if (Object.keys(state.sessions).length >= maxDevices) throw new Failure(429, 'device_limit');
        const token = crypto.randomBytes(32).toString('base64url');
        state.sessions[hash(token)] = { created: Date.now() }; save();
        return send(201, { token });
      }
      const token = (req.headers.authorization || '').replace(/^Bearer /, '');
      const id = hash(token);
      if (!state.sessions[id]) throw new Failure(401, 'unauthorized');
      const body = await readBody(req);
      const stats = validPayload(body), today = new Date().toISOString().slice(0, 10);
      const canonical = JSON.stringify(stats, function (key, value) {
        return value && typeof value === 'object' && !Array.isArray(value)
          ? Object.fromEntries(Object.keys(value).sort().map(k => [k, value[k]])) : value;
      });
      const cacheKey = hash(id + canonical);
      const cached = state.cache[cacheKey];
      if (cached && Date.now() - cached.created < 86400000) return send(200, { content: cached.content, cached: true });
      if (active.has(id)) throw new Failure(429, 'request_in_progress');
      if ((state.usage[today + ':' + id] || 0) >= limit || (state.usage[today] || 0) >= globalLimit) throw new Failure(429, 'daily_limit');
      if (!config.apiKey) throw new Failure(503, 'provider_not_configured');
      // Charge the attempt before awaiting inference: concurrent requests and restarts cannot bypass quotas.
      state.usage[today + ':' + id] = (state.usage[today + ':' + id] || 0) + 1;
      state.usage[today] = (state.usage[today] || 0) + 1;
      for (const key of Object.keys(state.usage)) if (!key.startsWith(today)) delete state.usage[key];
      for (const [key, value] of Object.entries(state.cache)) if (Date.now() - value.created >= 86400000) delete state.cache[key];
      save(); active.add(id);
      try {
        const content = validReply(await infer(stats, config), stats);
        state.cache[cacheKey] = { created: Date.now(), content }; save();
        return send(200, { content, cached: false });
      } finally { active.delete(id); }
    } catch (error) {
      // Never return upstream errors, credentials, request bodies or financial data.
      send(error instanceof Failure ? error.status : 502, { error: error instanceof Failure ? error.message : 'analysis_unavailable' });
    }
  });
  server.requestTimeout = 10000; server.headersTimeout = 10000;
  return server;
}
async function providerCall(stats, config) {
  const endpoint = config.provider === 'openrouter' ? 'https://openrouter.ai/api/v1/chat/completions' : 'https://api.groq.com/openai/v1/chat/completions';
  const response = await fetch(endpoint, { method: 'POST', signal: AbortSignal.timeout(15000),
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + config.apiKey },
    body: JSON.stringify({ model: config.model || (config.provider === 'openrouter' ? 'openrouter/free' : 'openai/gpt-oss-120b'),
      messages: [{ role: 'system', content: instruction + (stats.reports ? ' 여러 결산이 입력됩니다. reports 배열로 반환하고 각 원소는 동일한 id 및 분석 JSON인 content를 포함하세요.' : '') + ' budget은 현재 월간 예산 설정 참고값이며 과거 예산 또는 연간 합계가 아닙니다.' }, { role: 'user', content: JSON.stringify(stats) }],
      max_tokens: stats.reports ? 8192 : 2048, response_format: { type: 'json_object' } }) });
  if (!response.ok) throw new Error('Upstream failed');
  const result = await response.json();
  return JSON.parse(result.choices[0].message.content);
}
if (require.main === module) {
  createGateway({ invitation: process.env.ENROLLMENT_TOKEN, apiKey: process.env.AI_API_KEY,
    provider: process.env.AI_PROVIDER || 'groq', model: process.env.AI_MODEL,
    stateFile: process.env.STATE_FILE,
    maxDevices: Number(process.env.MAX_DEVICES || 10), dailyLimit: Number(process.env.DAILY_LIMIT || 8),
    globalLimit: Number(process.env.GLOBAL_DAILY_LIMIT || 100) })
    .listen(Number(process.env.PORT || 8787), '127.0.0.1', () => console.log('AI gateway listening on localhost; configure HTTPS proxy for devices.'));
}
module.exports = { createGateway, validStats, validResult, validPayload, validReply };
