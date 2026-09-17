const { test } = require('node:test');
const assert = require('node:assert/strict');
const { generate } = require('../scripts/generate-source.cjs');
test('SideStore versions and release URLs remain synchronized without using English app repo', () => {
  const feed = generate({ repository: 'owner/budget', version: '0.2.0', size: 12345, date: '2026-09-17T00:00:00Z' });
  assert.equal(feed.apps[0].bundleIdentifier, 'com.yunseok.aibudget');
  assert.equal(feed.apps[0].versions[0].version, '0.2.0');
  assert.equal(feed.apps[0].versions[0].downloadURL, 'https://github.com/owner/budget/releases/download/v0.2.0/AIBudget.ipa');
  assert.ok(!JSON.stringify(feed).includes('/english/'));
  assert.throws(() => generate({ repository: 'owner/budget', version: '$(bad)', size: 12345 }));
});
