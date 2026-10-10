// Pure/mocked tests only: no real provider, secret, or email recipient is used.
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { emailLicense, requireEmail, requireEmailRecipient } from '../../docs/api/_lib.mjs';

const SITE = 'https://payments.example.test';
const ENV = ['ALOUD_PAYMENT_MODE', 'ALOUD_ENABLE_LIVE_PAYMENTS', 'VERCEL_ENV',
  'ALOUD_EMAIL_ENABLED', 'RESEND_API_KEY', 'LICENSE_EMAIL_FROM', 'ALOUD_TEST_EMAIL_ALLOWLIST',
  'LICENSE_SIGNING_KEY', 'SITE_ORIGIN'];
const originalFetch = globalThis.fetch;
let calls;
beforeEach(() => {
  // Never inspect inherited payment secrets; replace/delete only this test's names.
  for (const name of ENV) delete process.env[name];
  const { privateKey } = generateKeyPairSync('ed25519');
  Object.assign(process.env, { ALOUD_EMAIL_ENABLED: 'true', RESEND_API_KEY: 're_fixtureOnly',
    LICENSE_EMAIL_FROM: 'Aloud <onboarding@resend.dev>', SITE_ORIGIN: SITE,
    LICENSE_SIGNING_KEY: privateKey.export({ format: 'pem', type: 'pkcs8' }) });
  calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    assert.equal(url, 'https://api.resend.com/emails');
    return Response.json({ id: 'email_fixtureOnly' });
  };
});
afterEach(() => {
  for (const name of ENV) delete process.env[name];
  globalThis.fetch = originalFetch;
});
const purchase = email => ({ object: 'checkout.session', id: 'cs_test_FixtureOnly',
  livemode: false, mode: 'payment', status: 'complete', payment_status: 'paid',
  metadata: { product: 'aloud' }, customer_details: { email },
  created: Math.floor(Date.now() / 1000) });

for (const value of [undefined, '', '*@example.test', 'buyer@example.test,',
  'buyer@example.test\n', 'buyer@example.test\u200b', 'Buyer <buyer@example.test>',
  'buyer@localhost', Array.from({ length: 21 }, (_, i) => `buyer${i}@example.test`).join(',')]) {
  test(`missing/malformed test allowlist denies email before provider: ${JSON.stringify(value)}`, async () => {
    if (value !== undefined) process.env.ALOUD_TEST_EMAIL_ALLOWLIST = value;
    assert.throws(() => requireEmail(), { status: 503 });
    await assert.rejects(emailLicense(purchase('buyer@example.test'), SITE), { status: 503 });
    assert.equal(calls.length, 0);
  });
}

test('only exact approved sandbox addresses can receive either purchase or restore mail', async () => {
  process.env.ALOUD_TEST_EMAIL_ALLOWLIST = 'buyer@example.test';
  for (const address of ['other@example.test', 'buyer+other@example.test',
    'buyer@example.test.attacker.test', 'buyer@example.invalid']) {
    for (const purpose of ['purchase', 'restore']) {
      await assert.rejects(emailLicense(purchase(address), SITE, purpose), { status: 403 });
    }
  }
  assert.equal(calls.length, 0);
});

test('approved case variants send only to that buyer, with no extra recipients', async () => {
  process.env.ALOUD_TEST_EMAIL_ALLOWLIST = 'buyer@example.test, second@example.test';
  assert.equal(await emailLicense(purchase('BUYER@EXAMPLE.TEST'), SITE), true);
  assert.equal(calls.length, 1);
  const body = JSON.parse(calls[0].options.body);
  assert.deepEqual(body.to, ['BUYER@EXAMPLE.TEST']);
  assert.equal(body.cc, undefined); assert.equal(body.bcc, undefined);
});

test('live mode does not inherit sandbox allowlist restrictions or enablement', () => {
  Object.assign(process.env, { ALOUD_PAYMENT_MODE: 'live', ALOUD_ENABLE_LIVE_PAYMENTS: 'true',
    VERCEL_ENV: 'production', ALOUD_TEST_EMAIL_ALLOWLIST: 'malformed' });
  assert.doesNotThrow(() => requireEmail());
  assert.doesNotThrow(() => requireEmailRecipient('actualbuyer@example.test'));
  process.env.ALOUD_ENABLE_LIVE_PAYMENTS = 'false';
  assert.throws(() => requireEmailRecipient('actualbuyer@example.test'), { status: 503 });
  assert.equal(calls.length, 0);
});
