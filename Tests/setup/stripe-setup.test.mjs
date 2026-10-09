import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectTestAccount, setupPlan } from '../../scripts/stripe-setup.mjs';

test('live or missing credentials fail before any request', async () => {
  for (const key of [undefined, 'sk_live_example', 'rk_live_example', 'pk_test_example',
    'sk_org_example', 'rk_test_', 'rk_test_example\n', 'rk_test_example extra', 'not-a-key']) {
    await assert.rejects(inspectTestAccount({ key, fetcher: () => assert.fail('network was called') }));
  }
});
test('restricted sandbox inspector remains GET-only with separate read-only permissions', async () => {
  const paths = [];
  const result = await inspectTestAccount({ key: 'rk_test_example', fetcher: async (url, init) => {
    assert.equal(init.method, 'GET');
    assert.equal(init.headers.Authorization, 'Bearer rk_test_example');
    paths.push(new URL(url).pathname);
    return Response.json(url.endsWith('/account') ? {} : { data: [], has_more: false });
  } });
  assert.equal(result.changesMade, false);
  assert.deepEqual(paths.sort(), ['/v1/account', '/v1/prices', '/v1/webhook_endpoints']);
});
test('inspector is GET-only, paginates and reports no private account data or webhook secret', async () => {
  const urls = [];
  const result = await inspectTestAccount({ key: 'sk_test_example', siteOrigin:'https://example.test', fetcher: async (url, init) => {
    assert.equal(init.method, 'GET'); urls.push(url);
    if (url.endsWith('/account')) return Response.json({ id: 'private-account', email: 'private@example.test', charges_enabled: true,
      payouts_enabled: false, requirements: { currently_due: ['individual.verification.document'] }, capabilities: { card_payments: 'active' } });
    if (url.includes('/prices')) return Response.json({ data: [{ id: 'price_1', lookup_key: 'aloud_launch', currency: 'usd', unit_amount: 999, type: 'one_time', product: 'aloud' }], has_more: false });
    if (!url.includes('starting_after')) return Response.json({ data: [{ id: 'we_1', url: 'https://example.test/old', secret: 'never-show-this' }], has_more: true });
    return Response.json({ data: [{ id: 'we_2', url: 'https://example.test/api/webhook', status: 'enabled', enabled_events: setupPlan.webhook.events }], has_more: false });
  } });
  assert.equal(result.changesMade, false); assert.equal(result.webhookConfigured, true);
  assert.equal(urls.filter(u => u.includes('/webhook_endpoints')).length, 2);
  assert.equal(JSON.stringify(result).includes('private'), false);
  assert.equal(JSON.stringify(result).includes('never-show-this'), false);
});
test('API failures do not emit raw error bodies or credentials', async () => {
  await assert.rejects(inspectTestAccount({ key: 'sk_test_example', fetcher: async () => new Response('secret error body', { status: 401 }) }),
    error => error.message.includes('401') && !error.message.includes('secret'));
});
