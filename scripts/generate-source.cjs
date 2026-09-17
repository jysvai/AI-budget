'use strict';
const fs = require('node:fs');
const path = require('node:path');
function generate({ repository, version, size, date = new Date().toISOString() }) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository || '') || !/^\d+\.\d+\.\d+$/.test(version || '') || !Number.isSafeInteger(size) || size <= 0) {
    throw new Error('Repository, semantic version and IPA size are required.');
  }
  const base = `https://github.com/${repository}/releases/download/v${version}`;
  return {
    name: '모아 가계부', identifier: 'com.yunseok.aibudget.source',
    sourceURL: `https://github.com/${repository}/releases/latest/download/apps.json`,
    apps: [{ name: '모아 가계부', bundleIdentifier: 'com.yunseok.aibudget', developerName: 'yunseok',
      localizedDescription: 'SMS 기반 자동 기록, 수동 수입·지출, 기간별 AI 결산을 제공하는 개인 가계부입니다.',
      iconURL: `https://raw.githubusercontent.com/${repository}/main/assets/app-icon.png`,
      versions: [{ version, date, localizedDescription: '앱 설정 및 개인정보 마스킹·취소·환불 기록 개선',
        downloadURL: `${base}/AIBudget.ipa`, size, minOSVersion: '17.0' }],
      appPermissions: { entitlements: ['com.apple.security.application-groups'], privacy: {} } }],
    news: []
  };
}
if (require.main === module) {
  const ipa = path.resolve('output/AIBudget.ipa');
  const source = generate({ repository: process.env.GITHUB_REPOSITORY, version: process.env.APP_VERSION, size: fs.statSync(ipa).size });
  fs.writeFileSync('output/apps.json', JSON.stringify(source, null, 2) + '\n');
}
module.exports = { generate };
