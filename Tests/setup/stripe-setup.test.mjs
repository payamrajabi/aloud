import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectTestAccount, setupPlan } from '../../scripts/stripe-setup.mjs';

test('live or missing credentials fail before any request', async () => {
  for (const key of [undefined, 'sk_live_example', 'not-a-key']) {
    await assert.rejects(inspectTestAccount({ key, fetcher: () => assert.fail('network was called') }));
  }
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
