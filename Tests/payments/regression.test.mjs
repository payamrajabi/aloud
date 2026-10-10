// All provider calls are mocked. Keys are generated in memory and never persisted.
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createHmac, verify } from 'node:crypto';
import { GET as buy } from '../../docs/api/buy.mjs';
import { GET as getLicense } from '../../docs/api/license.mjs';
import { POST as webhook } from '../../docs/api/webhook.mjs';
import { POST as restore } from '../../docs/api/restore.mjs';
import { licenseFor, isPaidAloud, fail, paymentMode, requireStripeMode, validEmail } from '../../docs/api/_lib.mjs';

const SITE = 'https://payments.example.test';
const WEBHOOK_SECRET = 'whsec_fixtureOnly';
const ENV = ['ALOUD_PAYMENT_MODE', 'ALOUD_ENABLE_LIVE_PAYMENTS', 'VERCEL_ENV', 'STRIPE_SECRET_KEY',
  'STRIPE_WEBHOOK_SECRET', 'SITE_ORIGIN', 'LICENSE_SIGNING_KEY', 'ALOUD_EMAIL_ENABLED',
  'RESEND_API_KEY', 'LICENSE_EMAIL_FROM', 'ALOUD_PRICE_LOOKUP_KEY', 'ALOUD_STRIPE_PRODUCT_ID',
  'ALOUD_RESTORE_PROTECTION_READY', 'ALOUD_APPROVED_PRICE_IDS', 'ALOUD_TEST_EMAIL_ALLOWLIST'];
const originalFetch = globalThis.fetch;
const originalError = console.error;
const originalNow = Date.now;
let calls, logs, keypair;
beforeEach(() => {
  // Delete, never inspect, any inherited payment configuration.
  for (const name of ENV) delete process.env[name];
  keypair = generateKeyPairSync('ed25519');
  Object.assign(process.env, { STRIPE_SECRET_KEY: 'sk_test_fixtureOnly', STRIPE_WEBHOOK_SECRET: WEBHOOK_SECRET,
    SITE_ORIGIN: SITE, LICENSE_SIGNING_KEY: keypair.privateKey.export({ format: 'pem', type: 'pkcs8' }),
    ALOUD_EMAIL_ENABLED: 'true', RESEND_API_KEY: 're_fixtureOnly', LICENSE_EMAIL_FROM: 'Aloud <license@example.test>',
    ALOUD_RESTORE_PROTECTION_READY: 'true', ALOUD_APPROVED_PRICE_IDS: 'price_fixture,price_HistoricalFixture',
    ALOUD_TEST_EMAIL_ALLOWLIST: 'buyer@example.test' }); // All provider calls below are mocked.
  calls = []; logs = [];
  console.error = (...args) => logs.push(args.join(' '));
  globalThis.fetch = async (...args) => { calls.push(args); throw new Error('Unexpected mocked provider call'); };
});
afterEach(() => {
  for (const name of ENV) delete process.env[name];
  globalThis.fetch = originalFetch; console.error = originalError; Date.now = originalNow;
});

function session(overrides = {}) {
  return { object: 'checkout.session', id: 'cs_test_Fixture123', livemode: false, mode: 'payment',
    status: 'complete', payment_status: 'paid', metadata: { product: 'aloud' },
    customer_details: { email: 'buyer@example.test' }, created: 1_759_968_000,
    managed_payments: { enabled: true }, currency: 'usd', amount_subtotal: 999, amount_total: 999, ...overrides };
}
function event(overrides = {}, purchase = session()) {
  return { object: 'event', id: 'evt_Fixture123', livemode: false, type: 'checkout.session.completed',
    data: { object: purchase }, ...overrides };
}
function request(path, options) { return new Request(`${SITE}${path}`, options); }
function signature(body, timestamp = Math.floor(Date.now() / 1000)) {
  return `t=${timestamp},v1=${createHmac('sha256', WEBHOOK_SECRET).update(`${timestamp}.${body}`).digest('hex')}`;
}
function hookRequest(value, header, raw = false) {
  const body = raw ? value : JSON.stringify(value);
  return request('/api/webhook', { method: 'POST', body,
    headers: header === null ? {} : { 'stripe-signature': header || signature(body) } });
}
function restoreRequest(email = 'buyer@example.test') {
  return request('/api/restore', { method: 'POST', body: new URLSearchParams({ email }) });
}
function mock(handler) {
  globalThis.fetch = async (url, options = {}) => {
    const call = { url: new URL(url), options };
    calls.push(call);
    if (call.url.hostname === 'api.stripe.com') assert.equal(options.headers['Stripe-Version'], '2026-04-22.dahlia');
    return handler(call, calls.length);
  };
}
function priceFixture(overrides = {}) {
  return { id: 'price_fixture', object: 'price', active: true, type: 'one_time', recurring: null,
    custom_unit_amount: null, transform_quantity: null, billing_scheme: 'per_unit', product: 'aloud',
    lookup_key: 'aloud_launch', currency: 'usd', livemode: false, unit_amount: 999, ...overrides };
}
function lineItems(overrides = {}, price = priceFixture()) {
  return { object: 'list', data: [{ id: 'li_Fixture123', object: 'item', price, quantity: 1,
    currency: 'usd', amount_subtotal: 999, amount_total: 999, ...overrides }], has_more: false };
}
// A tiny mocked Stripe receipt/state store, explicitly separate from Resend.
function mockPurchase(handler = () => Response.json({ id: 'email_fixture' }), options = {}) {
  let current = options.purchase || session();
  let forwarded = 0;
  mock(call => {
    const { url, options: init } = call;
    if (url.hostname === 'api.stripe.com') {
      if (url.pathname === `/v1/checkout/sessions/${current.id}`) {
        if (init.method === 'POST') {
          const fields = new URLSearchParams(init.body);
          const intercepted = options.markerWrite?.(call, current);
          if (intercepted !== undefined) return intercepted;
          const metadata = { ...current.metadata };
          for (const [key, value] of fields) if (key.startsWith('metadata[')) metadata[key.slice(9, -1)] = value;
          current = { ...current, metadata };
        }
        return Response.json(current);
      }
      if (url.pathname === `/v1/checkout/sessions/${current.id}/line_items`) {
        assert.equal(url.searchParams.get('limit'), '2');
        return Response.json(options.lines || lineItems());
      }
      if (url.pathname.startsWith('/v1/prices/')) {
        assert.equal(url.searchParams.get('expand[0]'), 'currency_options');
        return Response.json(options.price || priceFixture());
      }
    }
    return handler(call, ++forwarded);
  });
  return { get session() { return current; } };
}
function emails() { return calls.filter(call => call.url?.hostname === 'api.resend.com'); }

function checkoutMock(priceChanges = {}, sessionChanges = {}) {
  mock(({ url, options }) => {
    if (url.pathname === '/v1/prices') return Response.json({ data: [priceFixture(priceChanges)] });
    assert.equal(url.pathname, '/v1/checkout/sessions');
    const fields = new URLSearchParams(options.body);
    assert.equal(fields.get('managed_payments[enabled]'), 'true');
    assert.equal(fields.get('mode'), 'payment');
    assert.equal(fields.get('metadata[product]'), 'aloud');
    assert.equal(fields.get('line_items[0][price]'), 'price_fixture');
    assert.equal(fields.get('success_url'), `${SITE}/thanks?session_id={CHECKOUT_SESSION_ID}`);
    assert.equal(fields.get('cancel_url'), `${SITE}/#buy`);
    return Response.json(session({ status: 'open', payment_status: 'unpaid',
      url: 'https://checkout.stripe.com/c/pay/cs_test_Fixture123', ...sessionChanges }));
  });
}

for (const mode of ['test', 'live']) {
  for (const kind of ['sk', 'rk']) test(`${kind} ${mode} key is accepted only in its configured mode`, () => {
    Object.assign(process.env, { ALOUD_PAYMENT_MODE: mode, ALOUD_ENABLE_LIVE_PAYMENTS: 'true',
      VERCEL_ENV: 'production', STRIPE_SECRET_KEY: `${kind}_${mode}_fixtureOnly` });
    assert.equal(requireStripeMode(), mode);
    process.env.ALOUD_PAYMENT_MODE = mode === 'test' ? 'live' : 'test';
    assert.throws(() => requireStripeMode());
    assert.equal(calls.length, 0);
  });
}
for (const key of ['rk_live_fixtureOnly', 'pk_test_fixtureOnly', 'sk_org_fixtureOnly',
  'rk_test_', 'rk_test_fixtureOnly\n', 'rk_test_fixtureOnly extra', 'rk_test_fixture_Only']) {
  test(`invalid/wrong-mode runtime credential is rejected: ${JSON.stringify(key)}`, async () => {
    process.env.STRIPE_SECRET_KEY = key;
    assert.equal((await buy(request('/buy'))).status, 503);
    assert.equal(calls.length, 0);
  });
}
test('restricted test checkout forwards only the authorized restricted key to mocked Stripe', async () => {
  process.env.STRIPE_SECRET_KEY = 'rk_test_fixtureOnly'; checkoutMock();
  assert.equal((await buy(request('/buy'))).status, 303);
  assert.equal(calls.length, 2);
  assert.ok(calls.every(call => call.options.headers.Authorization === 'Bearer rk_test_fixtureOnly'));
});

for (const [name, env] of [
  ['live key in default test mode', { STRIPE_SECRET_KEY: 'sk_live_fixtureOnly' }],
  ['live billing without enable gate', { ALOUD_PAYMENT_MODE: 'live', STRIPE_SECRET_KEY: 'sk_live_fixtureOnly', VERCEL_ENV: 'production' }],
  ['live billing on preview', { ALOUD_PAYMENT_MODE: 'live', ALOUD_ENABLE_LIVE_PAYMENTS: 'true', STRIPE_SECRET_KEY: 'sk_live_fixtureOnly', VERCEL_ENV: 'preview' }],
  ['unknown payment mode', { ALOUD_PAYMENT_MODE: 'maybe' }],
  ['email disabled', { ALOUD_EMAIL_ENABLED: 'false' }],
  ['missing email key', { RESEND_API_KEY: '' }],
  ['missing email sender', { LICENSE_EMAIL_FROM: '' }],
  ['invalid signer', { LICENSE_SIGNING_KEY: 'not a key' }],
  ['missing Stripe key', { STRIPE_SECRET_KEY: '' }],
  ['missing webhook secret', { STRIPE_WEBHOOK_SECRET: '' }],
  ['malformed webhook secret', { STRIPE_WEBHOOK_SECRET: 'placeholder' }],
]) test(`checkout fails closed: ${name}`, async () => {
  Object.assign(process.env, env);
  assert.equal((await buy(request('/buy'))).status, 503);
  assert.equal(calls.length, 0);
});

test('default test checkout uses configured origin and ignores forwarded hosts', async () => {
  assert.equal(paymentMode(), 'test'); checkoutMock();
  const res = await buy(request('/buy', { headers: { 'x-forwarded-host': 'attacker.example', host: 'attacker.example' } }));
  assert.equal(res.status, 303); assert.equal(res.headers.get('location'), 'https://checkout.stripe.com/c/pay/cs_test_Fixture123');
  assert.equal(res.headers.get('cache-control'), 'no-store');
});
for (const site of ['', 'http://payments.example.test', `${SITE}/`, `${SITE}/path`, `${SITE}?query=yes`, 'https://user:password@payments.example.test']) {
  test(`reject invalid configured site: ${site || 'missing'}`, async () => {
    process.env.SITE_ORIGIN = site;
    assert.equal((await buy(request('/buy'))).status, 503); assert.equal(calls.length, 0);
  });
}
test('mismatched request host rejected before providers', async () => {
  assert.equal((await buy(new Request('https://attacker.example/buy'))).status, 400);
  assert.equal((await webhook(new Request('https://attacker.example/api/webhook', { method: 'POST', body: '{}' }))).status, 400);
  assert.equal(calls.length, 0);
});
for (const [name, change] of Object.entries({ product: { product: 'not-aloud' }, recurring: { type: 'recurring' },
  inactive: { active: false }, mode: { livemode: true }, lookup: { lookup_key: 'different' }, free: { unit_amount: 0 } })) {
  test(`checkout rejects ${name} price`, async () => {
    checkoutMock(change); assert.equal((await buy(request('/buy'))).status, 503); assert.equal(calls.length, 1);
  });
}
for (const url of ['https://attacker.example/pay', 'http://checkout.stripe.com/pay',
  'https://checkout.stripe.com.attacker.example/pay', 'https://user@checkout.stripe.com/pay',
  'https://checkout.stripe.com:444/pay', 'javascript:alert(1)']) {
  test(`checkout rejects untrusted redirect ${url}`, async () => {
    checkoutMock({}, { url }); assert.equal((await buy(request('/buy'))).status, 503);
  });
}

test('license is signed deterministically and carries test mode', async () => {
  mockPurchase();
  const res = await getLicense(request('/api/license?session_id=cs_test_Fixture123'));
  assert.equal(res.status, 200); const data = await res.json();
  assert.equal(data.mode, 'test'); assert.equal(data.license, licenseFor(session()));
  const [payload, sig] = data.license.split('.');
  assert.equal(verify(null, Buffer.from(payload, 'base64url'), keypair.publicKey, Buffer.from(sig, 'base64url')), true);
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url')), { product: 'aloud', mode: 'test',
    email: 'buyer@example.test', id: 'cs_test_Fixture123', issued: '2025-10-09' });
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
});
test('live mode needs both explicit enable and production, then signs live fixtures only', () => {
  Object.assign(process.env, { ALOUD_PAYMENT_MODE: 'live', ALOUD_ENABLE_LIVE_PAYMENTS: 'true', VERCEL_ENV: 'production' });
  const paid = session({ livemode: true, id: 'cs_live_Fixture123' });
  assert.equal(JSON.parse(Buffer.from(licenseFor(paid).split('.')[0], 'base64url')).mode, 'live');
  assert.throws(() => licenseFor(session()));
});
for (const [name, invoke] of [
  ['checkout', () => buy(request('/buy', { headers: { 'x-license-public-key': 'override' } }))],
  ['license', () => getLicense(request('/api/license?session_id=cs_live_Fixture123&issuer=override'))],
  ['restore', () => restore(restoreRequest())],
  ['webhook', () => webhook(hookRequest(event({ livemode: true }, session({ livemode: true, id: 'cs_live_Fixture123',
    metadata: { product: 'aloud', issuer: 'override' } }))))],
]) test(`wrong live signer blocks ${name} before provider calls`, async () => {
  Object.assign(process.env, { ALOUD_PAYMENT_MODE: 'live', ALOUD_ENABLE_LIVE_PAYMENTS: 'true',
    VERCEL_ENV: 'production', STRIPE_SECRET_KEY: 'sk_live_fixtureOnly' });
  assert.equal((await invoke()).status, 503);
  assert.equal(calls.length, 0);
});
test('a failed Managed Payments checkout never falls back to ordinary payments', async () => {
  mock(({ url, options }) => {
    if (url.pathname === '/v1/prices') return Response.json({ data: [priceFixture()] });
    assert.equal(url.pathname, '/v1/checkout/sessions');
    assert.equal(new URLSearchParams(options.body).get('managed_payments[enabled]'), 'true');
    return Response.json({ error: { message: 'Managed Payments not activated' } }, { status: 400 });
  });
  assert.equal((await buy(request('/buy'))).status, 503);
  assert.equal(calls.length, 2);
});
for (const [name, change] of Object.entries({ subscription: { mode: 'subscription' }, setup: { mode: 'setup' },
  open: { status: 'open' }, expired: { status: 'expired' }, unpaid: { payment_status: 'unpaid' },
  free: { payment_status: 'no_payment_required' }, product: { metadata: { product: 'other' } },
  object: { object: 'payment_intent' }, missingMode: { mode: undefined }, live: { livemode: true },
  id: { id: 'cs_live_Fixture123' }, email: { customer_details: { email: '' } },
  invalidEmail: { customer_details: { email: 'a\nb@example.test' } }, created: { created: 0 },
  future: { created: Math.floor(Date.now() / 1000) + 10000 } })) {
  test(`cannot sign ${name} session`, () => { assert.equal(isPaidAloud(session(change)), false); assert.throws(() => licenseFor(session(change))); });
}
test('email byte limit matches app verifier', () => { assert.equal(validEmail(`${'é'.repeat(125)}@example.test`), false); });
for (const char of ['\u007f', '\u0085', '\u009f', '\u200b']) {
  test(`email control/format U+${char.codePointAt(0).toString(16)} cannot produce an unusable app license`, () => {
    const email = `buy${char}er@example.test`;
    assert.equal(validEmail(email), false);
    assert.throws(() => licenseFor(session({ customer_details: { email } })));
  });
}
test('live session URL is rejected in default test before Stripe', async () => {
  assert.equal((await getLicense(request('/api/license?session_id=cs_live_Fixture123'))).status, 400); assert.equal(calls.length, 0);
});
test('complete unpaid purchase is pending, never a license', async () => {
  mock(() => Response.json(session({ payment_status: 'unpaid' })));
  const res = await getLicense(request('/api/license?session_id=cs_test_Fixture123'));
  assert.equal(res.status, 202); assert.deepEqual(await res.json(), { pending: true, mode: 'test' });
});
for (const change of [{ status: 'open' }, { status: 'expired' }, { mode: 'subscription' },
  { metadata: { product: 'wrong' } }, { customer_details: { email: '' } }, { id: 'cs_test_Different123' }]) {
  test(`license endpoint rejects ineligible fixture ${JSON.stringify(change)}`, async () => {
    mock(() => Response.json(session(change)));
    const res = await getLicense(request('/api/license?session_id=cs_test_Fixture123'));
    assert.equal(res.status, 404); assert.equal('license' in await res.json(), false);
  });
}

for (const [name, header] of [ ['unsigned', null], ['invalid', 't=1,v1=bad'],
  ['stale', (body) => signature(body, Math.floor(Date.now() / 1000) - 301)],
  ['future', (body) => signature(body, Math.floor(Date.now() / 1000) + 301)],
  ['wrong hash', () => `t=${Math.floor(Date.now() / 1000)},v1=${'0'.repeat(64)}`],
  ['ambiguous timestamps', (body) => `${signature(body)},t=${Math.floor(Date.now() / 1000)}`] ]) {
  test(`webhook rejects ${name} signature`, async () => {
    const body = JSON.stringify(event());
    assert.equal((await webhook(hookRequest(body, typeof header === 'function' ? header(body) : header, true))).status, 400);
    assert.equal(calls.length, 0);
  });
}
test('webhook rejects tampered signed body', async () => {
  const signed = JSON.stringify(event());
  assert.equal((await webhook(hookRequest(`${signed} `, signature(signed), true))).status, 400); assert.equal(calls.length, 0);
});
test('correctly signed invalid JSON is a 400 without raw logs', async () => {
  assert.equal((await webhook(hookRequest('{private', undefined, true))).status, 400);
  assert.equal(calls.length, 0); assert.deepEqual(logs, []);
});
test('webhook accepts one valid rotated signature', async () => {
  mockPurchase(() => Response.json({ id: 'email_fixture' }));
  const body = JSON.stringify(event());
  const res = await webhook(hookRequest(body, `${signature(body)},v1=${'0'.repeat(64)}`, true));
  assert.equal(res.status, 200); assert.equal(emails().length, 1);
});
for (const [name, evt] of [ ['live event', event({ livemode: true })],
  ['live session', event({}, session({ livemode: true, id: 'cs_live_Fixture123' }))],
  ['subscription', event({}, session({ mode: 'subscription' }))],
  ['open', event({}, session({ status: 'open' }))], ['missing email', event({}, session({ customer_details: null }))] ]) {
  test(`webhook rejects ${name}`, async () => {
    assert.equal((await webhook(hookRequest(evt))).status, 400); assert.equal(calls.length, 0);
  });
}
test('webhook rejects live Stripe key in default test', async () => {
  process.env.STRIPE_SECRET_KEY = 'sk_live_fixtureOnly';
  assert.equal((await webhook(hookRequest(event()))).status, 503); assert.equal(calls.length, 0);
});
for (const evt of [event({ type: 'unhandled.event' }), event({}, session({ payment_status: 'unpaid' })),
  event({}, session({ metadata: { product: 'other' } }))]) {
  test(`irrelevant/unpaid event ${JSON.stringify(evt)} is acknowledged without delivery`, async () => {
    assert.equal((await webhook(hookRequest(evt))).status, 200); assert.equal(calls.length, 0);
  });
}
for (const env of [{ ALOUD_EMAIL_ENABLED: 'false' }, { RESEND_API_KEY: '' }, { LICENSE_EMAIL_FROM: '' },
  { LICENSE_SIGNING_KEY: '' }, { STRIPE_WEBHOOK_SECRET: '' }]) {
  test(`missing delivery/verification config retries: ${JSON.stringify(env)}`, async () => {
    Object.assign(process.env, env);
    assert.equal((await webhook(hookRequest(event()))).status, 503); assert.equal(calls.length, 0);
  });
}
test('completed and async events for one purchase use identical provider idempotency', async () => {
  const accepted = new Map();
  mockPurchase(({ url, options }) => {
    assert.equal(url.href, 'https://api.resend.com/emails');
    const key = options.headers['Idempotency-Key'];
    if (accepted.has(key)) assert.equal(options.body, accepted.get(key)); else accepted.set(key, options.body);
    return Response.json({ id: 'email_fixture' });
  });
  assert.equal((await webhook(hookRequest(event()))).status, 200);
  assert.equal((await webhook(hookRequest(event({ id: 'evt_Async456', type: 'checkout.session.async_payment_succeeded' })))).status, 200);
  assert.equal(emails().length, 1); assert.equal(accepted.size, 1);
  assert.equal(emails()[0].options.headers['Idempotency-Key'], 'aloud/test/cs_test_Fixture123/purchase');
});
test('delivery timeout or concurrent conflict remains retryable with same key/body', async () => {
  let first;
  mockPurchase(({ options }, count) => {
    if (count === 1) { first = options; throw new Error('provider accepted then timed out buyer@example.test re_private'); }
    assert.equal(options.headers['Idempotency-Key'], first.headers['Idempotency-Key']);
    assert.equal(options.body, first.body);
    return count === 2 ? Response.json({ message: 'sensitive provider body' }, { status: 409 }) : Response.json({ id: 'email_fixture' });
  });
  assert.equal((await webhook(hookRequest(event()))).status, 502);
  assert.equal((await webhook(hookRequest(event()))).status, 502);
  assert.equal((await webhook(hookRequest(event()))).status, 200); assert.deepEqual(logs, []);
});

for (const value of [undefined, '', 'false', 'TRUE', '1']) {
  test(`restore protection defaults closed without exact operator attestation: ${String(value)}`, async () => {
    if (value === undefined) delete process.env.ALOUD_RESTORE_PROTECTION_READY;
    else process.env.ALOUD_RESTORE_PROTECTION_READY = value;
    const res = await restore(restoreRequest());
    assert.equal(res.status, 503); assert.equal(calls.length, 0);
    assert.match((await res.json()).error, /Contact support/);
    assert.deepEqual(logs, []);
  });
}
test('request headers, query and form cannot enable restore protection', async () => {
  delete process.env.ALOUD_RESTORE_PROTECTION_READY;
  const res = await restore(request('/api/restore?ALOUD_RESTORE_PROTECTION_READY=true', { method: 'POST',
    headers: { 'x-aloud-restore-protection-ready': 'true', 'ALOUD_RESTORE_PROTECTION_READY': 'true' },
    body: new URLSearchParams({ email: 'buyer@example.test', ALOUD_RESTORE_PROTECTION_READY: 'true' }) }));
  assert.equal(res.status, 503); assert.equal(calls.length, 0);
});
test('restore protection attestation does not enable live mode or affect checkout', async () => {
  delete process.env.ALOUD_RESTORE_PROTECTION_READY;
  checkoutMock();
  assert.equal((await buy(request('/buy'))).status, 303);
  assert.equal(calls.length, 2);
  process.env.ALOUD_RESTORE_PROTECTION_READY = 'true';
  process.env.STRIPE_SECRET_KEY = 'rk_live_fixtureOnly';
  calls.length = 0;
  assert.equal((await restore(restoreRequest())).status, 503);
  assert.equal(calls.length, 0);
});
test('restore filters email and paginates beyond 20 historical purchases', async () => {
  Date.now = () => 1_791_547_200_000;
  const old = Array.from({ length: 25 }, (_, i) => session({ id: `cs_test_Old${i}`, metadata: { product: 'other' } }));
  mockPurchase(({ url, options }) => {
    if (url.hostname === 'api.resend.com') {
      assert.deepEqual(JSON.parse(options.body).to, ['buyer@example.test']);
      assert.match(options.headers['Idempotency-Key'], /^aloud\/test\/cs_test_Fixture123\/restore\/\d+$/);
      return Response.json({ id: 'email_fixture' });
    }
    assert.equal(url.searchParams.get('customer_details[email]'), 'buyer@example.test');
    assert.equal(url.searchParams.get('status'), 'complete'); assert.equal(url.searchParams.get('limit'), '100');
    return url.searchParams.get('starting_after') === 'cs_test_Old24'
      ? Response.json({ data: [session()], has_more: false }) : Response.json({ data: old, has_more: true });
  });
  const res = await restore(restoreRequest()); assert.equal(res.status, 200); assert.deepEqual(await res.json(), { sent: true });
  assert.equal(calls.length, 6);
});
test('restore does not send another buyer’s license from overbroad Stripe results', async () => {
  mock(() => Response.json({ data: [session({ customer_details: { email: 'someoneelse@example.test' } })], has_more: false }));
  const res = await restore(restoreRequest()); assert.equal(res.status, 200); assert.deepEqual(await res.json(), { sent: true });
  assert.equal(calls.length, 1);
});
test('restore tries typed and lowercase email, verifies recipient', async () => {
  mockPurchase(({ url, options }) => url.hostname === 'api.resend.com' ? Response.json({ id: 'email_fixture' })
    : Response.json({ data: url.searchParams.get('customer_details[email]') === 'buyer@example.test' ? [session()] : [], has_more: false }));
  assert.equal((await restore(restoreRequest('Buyer@Example.test'))).status, 200);
  assert.equal(calls.length, 6);
});
test('restore public result identical for absent purchase and failed delivery', async () => {
  mockPurchase(() => Response.json({ data: [], has_more: false }));
  const absent = await restore(restoreRequest());
  mockPurchase(({ url }) => url.hostname === 'api.resend.com' ? Response.json({ error: 'buyer@example.test secret' }, { status: 500 })
    : Response.json({ data: [session()], has_more: false }));
  const failed = await restore(restoreRequest());
  assert.equal(absent.status, failed.status); assert.deepEqual(await absent.json(), await failed.json());
  assert.deepEqual(logs, ['License restore lookup or delivery failed.']);
});
for (const page of [{ data: [], has_more: true }, { data: null, has_more: true },
  { data: [session({ metadata: { product: 'wrong' } })], has_more: true }]) {
  test(`restore bounds malformed or stuck pagination ${JSON.stringify(page)}`, async () => {
    mockPurchase(() => Response.json(page));
    assert.equal((await restore(restoreRequest())).status, 200); assert.ok(calls.length <= 2);
    assert.deepEqual(logs, ['License restore lookup or delivery failed.']);
  });
}
test('restore delivery keys are separate from purchase and stable within an hour', async () => {
  Date.now = () => 1_791_547_200_000;
  mockPurchase(({ url }) => url.hostname === 'api.resend.com' ? Response.json({ id: 'email_fixture' })
    : Response.json({ data: [session()], has_more: false }));
  assert.equal((await webhook(hookRequest(event()))).status, 200);
  assert.equal((await restore(restoreRequest())).status, 200);
  assert.equal((await restore(restoreRequest())).status, 200);
  const keys = calls.filter((call) => call.url.hostname === 'api.resend.com').map((call) => call.options.headers['Idempotency-Key']);
  assert.notEqual(keys[0], keys[1]); assert.equal(keys[1], keys[2]);
});
test('invalid restore email rejected without provider lookup', async () => {
  assert.equal((await restore(restoreRequest('invalid'))).status, 400); assert.equal(calls.length, 0);
});
test('restore recovery remains available if only webhook verification is misconfigured', async () => {
  process.env.STRIPE_WEBHOOK_SECRET = '';
  mockPurchase(({ url }) => url.hostname === 'api.resend.com' ? Response.json({ id: 'email_fixture' })
    : Response.json({ data: [session()], has_more: false }));
  assert.equal((await restore(restoreRequest())).status, 200);
  assert.equal(calls.length, 5);
});
test('provider errors and unexpected exceptions never expose sensitive data in logs/responses', async () => {
  mock(() => Response.json({ error: { message: 'sk_live_SECRET buyer@example.test signed-license' } }, { status: 500 }));
  const response = await getLicense(request('/api/license?session_id=cs_test_Fixture123'));
  assert.equal(response.status, 502); assert.equal((await response.text()).includes('SECRET'), false); assert.deepEqual(logs, []);
  const unknown = fail(new Error('PEM private key buyer@example.test sk_SECRET'));
  assert.equal((await unknown.text()).includes('SECRET'), false); assert.deepEqual(logs, ['Payment request failed.']);
});

// Actual provider receipts, not signed event metadata, authorize fulfillment.
for (const managed of [undefined, null, { enabled: false }, { enabled: 'true' }]) {
  test(`checkout never redirects without returned Managed Payments proof: ${JSON.stringify(managed)}`, async () => {
    checkoutMock({}, { managed_payments: managed });
    const res = await buy(request('/buy'));
    assert.equal(res.status, 503); assert.equal(res.headers.get('location'), null);
    assert.equal(calls.length, 2);
  });
  test(`license rejects missing/false provider Managed Payments proof: ${JSON.stringify(managed)}`, async () => {
    mockPurchase(undefined, { purchase: session({ managed_payments: managed }) });
    const res = await getLicense(request('/api/license?session_id=cs_test_Fixture123'));
    assert.equal(res.status, 404); assert.equal('license' in await res.json(), false);
    assert.equal(calls.length, 1); assert.equal(emails().length, 0);
  });
}
for (const ids of [undefined, '', 'price_', 'price_fixture,not-price', 'price_fixture\nextra']) {
  test(`missing/malformed approved price list blocks every entry point: ${String(ids)}`, async () => {
    if (ids === undefined) delete process.env.ALOUD_APPROVED_PRICE_IDS;
    else process.env.ALOUD_APPROVED_PRICE_IDS = ids;
    assert.equal((await buy(request('/buy'))).status, 503);
    assert.equal((await getLicense(request('/api/license?session_id=cs_test_Fixture123'))).status, 503);
    assert.equal((await webhook(hookRequest(event()))).status, 503);
    assert.equal((await restore(restoreRequest())).status, 503);
    assert.equal(calls.length, 0);
  });
}
test('unapproved new price cannot be sold even with Aloud product metadata and lookup', async () => {
  checkoutMock({ id: 'price_Unapproved' });
  assert.equal((await buy(request('/buy'))).status, 503); assert.equal(calls.length, 1);
});
const ineligibleReceipts = [
  ['wrong product', { price: priceFixture({ product: 'prod_Other' }) }],
  ['unapproved price', { lines: lineItems({}, priceFixture({ id: 'price_Other' })) }],
  ['recurring price', { price: priceFixture({ type: 'recurring', recurring: { interval: 'month' } }) }],
  ['wrong price mode', { price: priceFixture({ livemode: true }) }],
  ['different returned price', { price: priceFixture({ id: 'price_Different' }) }],
  ['zero quantity', { lines: lineItems({ quantity: 0 }) }],
  ['two quantities', { lines: lineItems({ quantity: 2 }) }],
  ['string quantity', { lines: lineItems({ quantity: '1' }) }],
  ['partial list', { lines: { ...lineItems(), has_more: true } }],
  ['missing has_more', { lines: { object: 'list', data: lineItems().data } }],
  ['two items', { lines: { ...lineItems(), data: [...lineItems().data, ...lineItems().data] } }],
  ['empty list', { lines: { ...lineItems(), data: [] } }],
  ['malformed list', { lines: { object: 'list', data: null, has_more: false } }],
  ['wrong currency', { lines: lineItems({ currency: 'cad' }) }],
  ['zero price', { price: priceFixture({ unit_amount: 0 }) }],
  ['transformed price', { price: priceFixture({ transform_quantity: { divide_by: 10, round: 'up' } }) }],
  ['custom price', { price: priceFixture({ custom_unit_amount: { minimum: 1 } }) }],
  ['wrong subtotal', { lines: lineItems({ amount_subtotal: 998 }) }],
  ['wrong total', { lines: lineItems({ amount_total: 1000 }) }],
];
for (const [name, fixture] of ineligibleReceipts) {
  test(`canonical ${name} receipt cannot issue a license or send an email`, async () => {
    mockPurchase(undefined, fixture);
    const response = await getLicense(request('/api/license?session_id=cs_test_Fixture123'));
    assert.equal(response.status, 404); assert.equal('license' in await response.json(), false);
    assert.equal(emails().length, 0);
    assert.equal(calls.filter(call => call.options.method === 'POST').length, 0);
  });
}
test('archived historical approved price remains valid after lookup moves', async () => {
  mockPurchase(undefined, { price: priceFixture({ active: false, lookup_key: null }) });
  const res = await getLicense(request('/api/license?session_id=cs_test_Fixture123'));
  assert.equal(res.status, 200); assert.equal(calls.length, 3);
});
test('provider currency option is verified without hardcoded launch amounts', async () => {
  mockPurchase(undefined, { purchase: session({ currency: 'cad', amount_subtotal: 1234, amount_total: 1400 }),
    price: priceFixture({ currency_options: { cad: { unit_amount: 1234 } } }),
    lines: lineItems({ currency: 'cad', amount_subtotal: 1234, amount_total: 1400 }) });
  assert.equal((await getLicense(request('/api/license?session_id=cs_test_Fixture123'))).status, 200);
});
test('webhook uses canonical provider address and MoR state rather than event fields', async () => {
  mockPurchase();
  const forged = session({ customer_details: { email: 'other@example.test' }, managed_payments: undefined });
  assert.equal((await webhook(hookRequest(event({}, forged)))).status, 200);
  assert.deepEqual(JSON.parse(emails()[0].options.body).to, ['buyer@example.test']);
});
test('Aloud metadata and a managed event cannot override ordinary canonical checkout', async () => {
  mockPurchase(undefined, { purchase: session({ managed_payments: { enabled: false } }) });
  assert.equal((await webhook(hookRequest(event()))).status, 404);
  assert.equal(emails().length, 0);
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 0);
});
for (const field of ['account', 'context']) test(`unsupported ${field} webhook source cannot cross account boundaries`, async () => {
  assert.equal((await webhook(hookRequest(event({ [field]: 'other-account' })))).status, 400);
  assert.equal(calls.length, 0);
});
test('restore skips newer ordinary session and recovers older approved managed purchase', async () => {
  const ordinary = session({ id: 'cs_test_OrdinaryNew', managed_payments: { enabled: false } });
  mockPurchase(({ url }) => Response.json(url.pathname.endsWith('/cs_test_OrdinaryNew') ? ordinary
    : { data: [ordinary, session()], has_more: false }));
  assert.equal((await restore(restoreRequest())).status, 200);
  assert.equal(emails().length, 1); assert.deepEqual(logs, []);
});
test('restore re-checks canonical recipient after list lookup before sending', async () => {
  mockPurchase(() => Response.json({ data: [session()], has_more: false }),
    { purchase: session({ customer_details: { email: 'other@example.test' } }) });
  assert.equal((await restore(restoreRequest())).status, 200);
  assert.equal(emails().length, 0); assert.deepEqual(logs, []);
});
test('restore caps candidate verification work without revealing purchase state', async () => {
  const rows = Array.from({ length: 101 }, (_, i) => session({ id: `cs_test_Candidate${i}` }));
  mock(({ url }) => Response.json(url.pathname === '/v1/checkout/sessions'
    ? { data: rows, has_more: false } : session({ id: url.pathname.split('/').at(-1), managed_payments: null })));
  assert.equal((await restore(restoreRequest())).status, 200);
  assert.equal(calls.length, 101); assert.equal(emails().length, 0);
  assert.deepEqual(logs, ['License restore lookup or delivery failed.']);
});

// Stripe session metadata survives cold starts and Resend's idempotency-key expiry.
const RETRY_NOW = 1_791_547_200_000;
test('attempt precedes email, acknowledgement follows acceptance, and >24h replay never resends', async () => {
  Date.now = () => RETRY_NOW;
  const state = mockPurchase();
  assert.equal((await webhook(hookRequest(event()))).status, 200);
  const writes = calls.filter(call => call.options.method === 'POST');
  assert.equal(new URLSearchParams(writes[0].options.body).get('metadata[aloud_email_attempt_at]'), String(RETRY_NOW / 1000));
  assert.equal(writes[1].url.hostname, 'api.resend.com');
  assert.equal(new URLSearchParams(writes[2].options.body).get('metadata[aloud_email_accepted]'), 'v1');
  assert.equal(writes[0].options.headers['Idempotency-Key'], 'aloud/test/cs_test_Fixture123/email-attempt-v1');
  assert.equal(writes[2].options.headers['Idempotency-Key'], 'aloud/test/cs_test_Fixture123/email-accepted-v1');
  assert.deepEqual(state.session.metadata, { product: 'aloud', aloud_email_attempt_at: String(RETRY_NOW / 1000), aloud_email_accepted: 'v1' });
  Date.now = () => RETRY_NOW + 3 * 86_400_000;
  assert.equal((await webhook(hookRequest(event({ id: 'evt_ReplayLater' })))).status, 200);
  assert.equal(emails().length, 1); assert.equal(calls.filter(call => call.options.method === 'POST').length, 3);
});
test('pre-execution acknowledgement conflict can retry within23h using identical Resend body/key', async () => {
  Date.now = () => RETRY_NOW;
  let rejectAck = true;
  mockPurchase(() => Response.json({ id: 'email_fixture' }), { markerWrite: ({ options }) => {
    if (new URLSearchParams(options.body).has('metadata[aloud_email_accepted]') && rejectAck) {
      rejectAck = false; return Response.json({ error: 'request in progress' }, { status: 409 });
    }
  } });
  assert.equal((await webhook(hookRequest(event()))).status, 502);
  Date.now = () => RETRY_NOW + 22 * 3_600_000;
  assert.equal((await webhook(hookRequest(event()))).status, 200);
  assert.equal(emails().length, 2);
  assert.equal(emails()[0].options.body, emails()[1].options.body);
  assert.equal(emails()[0].options.headers['Idempotency-Key'], emails()[1].options.headers['Idempotency-Key']);
  assert.deepEqual(logs, []);
});
test('unacknowledged acceptance after23h fails closed rather than replaying expired provider keys', async () => {
  Date.now = () => RETRY_NOW;
  mockPurchase(undefined, { markerWrite: ({ options }) => new URLSearchParams(options.body).has('metadata[aloud_email_accepted]')
    ? Response.json({ error: 'failed ack' }, { status: 500 }) : undefined });
  assert.equal((await webhook(hookRequest(event()))).status, 502);
  Date.now = () => RETRY_NOW + 23 * 3_600_000;
  const later = await webhook(hookRequest(event()));
  assert.equal(later.status, 503); assert.match((await later.json()).error, /manual reconciliation/);
  assert.equal(emails().length, 1);
});
test('pre-execution attempt marker conflict never sends email; safe retry stores marker first', async () => {
  Date.now = () => RETRY_NOW;
  let reject = true;
  mockPurchase(undefined, { markerWrite: ({ options }) => {
    if (new URLSearchParams(options.body).has('metadata[aloud_email_attempt_at]') && reject) {
      reject = false; return Response.json({ error: 'request in progress' }, { status: 409 });
    }
  } });
  assert.equal((await webhook(hookRequest(event()))).status, 502); assert.equal(emails().length, 0);
  assert.equal((await webhook(hookRequest(event()))).status, 200); assert.equal(emails().length, 1);
});
test('persisted attempt followed by timeout remains bounded by original timestamp', async () => {
  Date.now = () => RETRY_NOW;
  let reject = true;
  mockPurchase(undefined, { markerWrite: ({ options }, current) => {
    const value = new URLSearchParams(options.body).get('metadata[aloud_email_attempt_at]');
    if (value && reject) {
      reject = false; current.metadata.aloud_email_attempt_at = value; throw new Error('accepted state then timeout');
    }
  } });
  assert.equal((await webhook(hookRequest(event()))).status, 502); assert.equal(emails().length, 0);
  Date.now = () => RETRY_NOW + 24 * 3_600_000;
  assert.equal((await webhook(hookRequest(event()))).status, 503); assert.equal(emails().length, 0);
});
for (const metadata of [
  { aloud_email_attempt_at: 'not-a-time' }, { aloud_email_attempt_at: '' },
  { aloud_email_attempt_at: String(RETRY_NOW / 1000 + 1) },
  { aloud_email_attempt_at: `0${RETRY_NOW / 1000}` },
  { aloud_email_attempt_at: String(RETRY_NOW / 1000 - 24 * 3600) },
  { aloud_email_accepted: 'v1' },
  { aloud_email_attempt_at: String(RETRY_NOW / 1000), aloud_email_accepted: 'unknown' },
]) test(`ambiguous/stale durable state never resends: ${JSON.stringify(metadata)}`, async () => {
  Date.now = () => RETRY_NOW;
  mockPurchase(undefined, { purchase: session({ metadata: { product: 'aloud', ...metadata } }) });
  assert.equal((await webhook(hookRequest(event()))).status, 503);
  assert.equal(emails().length, 0); assert.equal(calls.filter(call => call.options.method === 'POST').length, 0);
});
test('unapproved test recipient is rejected before any metadata write or email', async () => {
  mockPurchase(undefined, { purchase: session({ customer_details: { email: 'unapproved@example.test' } }) });
  assert.equal((await webhook(hookRequest(event()))).status, 403);
  assert.equal(emails().length, 0); assert.equal(calls.filter(call => call.options.method === 'POST').length, 0);
});

test('concurrent purchase events share Stripe marker keys and one Resend acceptance', async () => {
  Date.now = () => RETRY_NOW;
  const accepted = new Map();
  mockPurchase(({ url, options }) => {
    assert.equal(url.hostname, 'api.resend.com');
    const key = options.headers['Idempotency-Key'];
    if (accepted.has(key)) assert.equal(options.body, accepted.get(key)); else accepted.set(key, options.body);
    return Response.json({ id: 'email_fixture' });
  });
  const results = await Promise.all([webhook(hookRequest(event())),
    webhook(hookRequest(event({ id: 'evt_Concurrent', type: 'checkout.session.async_payment_succeeded' })))]);
  assert.deepEqual(results.map(res => res.status), [200, 200]);
  assert.equal(accepted.size, 1); assert.equal(emails().length, 2);
  const stripeKeys = calls.filter(call => call.url.hostname === 'api.stripe.com' && call.options.method === 'POST')
    .map(call => call.options.headers['Idempotency-Key']);
  assert.equal(new Set(stripeKeys).size, 2);
});
test('concurrent different-timestamp attempt write conflict retries through canonical acknowledgement', async () => {
  let now = RETRY_NOW;
  Date.now = () => now;
  const attempts = new Map();
  mockPurchase(undefined, { markerWrite: ({ options }) => {
    if (!new URLSearchParams(options.body).has('metadata[aloud_email_attempt_at]')) return;
    const key = options.headers['Idempotency-Key'];
    if (attempts.has(key)) {
      if (attempts.get(key) !== String(options.body)) return Response.json({ error: 'idempotency body conflict' }, { status: 409 });
    } else {
      attempts.set(key, String(options.body)); now += 1000;
    }
  } });
  const results = await Promise.all([webhook(hookRequest(event())), webhook(hookRequest(event({ id: 'evt_Concurrent' })))]);
  assert.deepEqual(results.map(res => res.status).sort(), [200, 502]);
  assert.equal(emails().length, 1);
  assert.equal((await webhook(hookRequest(event({ id: 'evt_ConflictRetry' })))).status, 200);
  assert.equal(emails().length, 1); assert.deepEqual(logs, []);
});

for (const [name, change] of [
  ['transformed', { transform_quantity: { divide_by: 10, round: 'up' } }],
  ['custom', { custom_unit_amount: { minimum: 1 } }],
  ['tiered', { billing_scheme: 'tiered' }],
  ['recurring details', { recurring: { interval: 'month' } }],
  ['missing currency', { currency: undefined }],
]) test(`checkout blocks ${name} price before a customer could pay and fail fulfillment`, async () => {
  checkoutMock(change);
  assert.equal((await buy(request('/buy'))).status, 503);
  assert.equal(calls.length, 1);
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 0);
});
test('cached Stripe acknowledgement500 cannot repair automatically and eventually requires reconciliation', async () => {
  Date.now = () => RETRY_NOW;
  const cached = new Map(), accepted = new Map();
  mockPurchase(({ options }) => {
    const key = options.headers['Idempotency-Key'];
    if (accepted.has(key)) assert.equal(options.body, accepted.get(key)); else accepted.set(key, options.body);
    return Response.json({ id: 'email_fixture' });
  }, { markerWrite: ({ options }) => {
    if (!new URLSearchParams(options.body).has('metadata[aloud_email_accepted]')) return;
    const key = options.headers['Idempotency-Key'];
    if (cached.has(key)) assert.equal(String(options.body), cached.get(key)); else cached.set(key, String(options.body));
    return Response.json({ error: 'cached Stripe500' }, { status: 500 });
  } });
  assert.equal((await webhook(hookRequest(event()))).status, 502);
  Date.now = () => RETRY_NOW + 22 * 3_600_000;
  assert.equal((await webhook(hookRequest(event()))).status, 502);
  assert.equal(emails().length, 2); assert.equal(accepted.size, 1); assert.equal(cached.size, 1);
  Date.now = () => RETRY_NOW + 24 * 3_600_000;
  assert.equal((await webhook(hookRequest(event()))).status, 503);
  assert.equal(emails().length, 2); assert.deepEqual(logs, []);
});
