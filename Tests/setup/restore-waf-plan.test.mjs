import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

test('proposed WAF rule is inactive and cannot broaden beyond sandbox POST restore', () => {
  const rule = JSON.parse(readFileSync(new URL('../../ops/restore-waf-rule.preview.json', import.meta.url), 'utf8'));
  assert.equal(rule.active, false);
  assert.deepEqual(rule.conditionGroup, [{ conditions: [
    { type: 'host', op: 'eq', value: 'payments-test.aloudformac.com' },
    { type: 'path', op: 'eq', value: '/api/restore' },
    { type: 'method', op: 'eq', value: 'POST' },
  ] }]);
  assert.deepEqual(rule.action, { mitigate: { action: 'rate_limit', rateLimit: {
    algo: 'fixed_window', window: 600, limit: 5, keys: ['ip'], action: 'rate_limit',
  } } });
});
