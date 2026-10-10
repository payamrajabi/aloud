// Executes the actual page script against a minimal DOM and mocked HTTP responses.
// No browser, WAF, provider, credential or environment configuration is required.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const html = readFileSync(new URL('../../docs/restore.html', import.meta.url), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
function page(response) {
  const button = { disabled: false };
  const error = { hidden: true, textContent: '' };
  const sent = { hidden: true };
  let submit, now = 1_791_547_200_000, requests = 0;
  const timers = [];
  const form = { hidden: false, querySelector: () => button,
    addEventListener: (name, fn) => { assert.equal(name, 'submit'); submit = fn; } };
  runInNewContext(script, {
    document: { getElementById: id => ({ form, error, sent })[id] },
    FormData: class { constructor(value) { assert.equal(value, form); } },
    Date: { now: () => now, parse: Date.parse },
    fetch: async (path, init) => {
      assert.equal(path, '/api/restore'); assert.equal(init.method, 'POST');
      requests++;
      return typeof response === 'function' ? response(requests) : response;
    },
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); },
  });
  return { button, error, sent, form, timers, get requests() { return requests; },
    submit: () => submit({ preventDefault() {} }),
    advance: () => { const timer = timers.shift(); now += timer.ms; timer.fn(); } };
}

test('HTML WAF 429 shows helpful wait and re-enables only manual retry', async () => {
  const p = page(n => n === 1 ? new Response('<html>WAF limit</html>', { status: 429, headers: { 'Retry-After': '120' } })
    : Response.json({ sent: true }));
  await p.submit();
  assert.match(p.error.textContent, /wait 2 minutes/); assert.equal(p.error.hidden, false);
  assert.equal(p.button.disabled, true); assert.equal(p.form.hidden, false); assert.equal(p.sent.hidden, true);
  assert.equal(p.timers[0].ms, 120_000);
  await p.submit(); assert.equal(p.requests, 1);
  p.advance(); assert.equal(p.button.disabled, false); assert.equal(p.requests, 1);
  await p.submit(); assert.equal(p.requests, 2); assert.equal(p.sent.hidden, false);
});
for (const header of [undefined, 'garbage', '-1', '999999999999']) {
  test(`429 invalid/missing Retry-After uses 10 minutes: ${String(header)}`, async () => {
    const p = page(new Response('not JSON', { status: 429, headers: header === undefined ? {} : { 'Retry-After': header } }));
    await p.submit();
    assert.match(p.error.textContent, /wait 10 minutes/);
    assert.equal(p.timers[0].ms, 600_000); assert.equal(p.requests, 1);
    assert.equal(p.button.disabled, true);
  });
}
test('429 HTTP-date Retry-After is honored without an automatic provider retry', async () => {
  const p = page(new Response('WAF', { status: 429, headers: { 'Retry-After': new Date(1_791_547_200_000 + 180_000).toUTCString() } }));
  await p.submit(); assert.equal(p.timers[0].ms, 180_000);
  p.advance(); assert.equal(p.requests, 1); assert.equal(p.button.disabled, false);
});
test('HTML 503 from local mock remains usable with a helpful recovery message', async () => {
  const p = page(new Response('Local simulation: payments and email are disabled.', { status: 503 }));
  await p.submit();
  assert.match(p.error.textContent, /temporarily unavailable/); assert.equal(p.button.disabled, false);
  assert.equal(p.sent.hidden, true); assert.equal(p.timers.length, 0);
  assert.equal(p.error.textContent.includes('Unexpected token'), false);
});
test('restore readiness 503 preserves the support message and does not claim email sent', async () => {
  const p = page(Response.json({ error: 'License recovery isn’t available yet. Contact support for help.' }, { status: 503 }));
  await p.submit(); assert.match(p.error.textContent, /Contact support/);
  assert.equal(p.button.disabled, false); assert.equal(p.form.hidden, false); assert.equal(p.sent.hidden, true);
});
test('successful restore shows the same non-enumerating result without retries', async () => {
  const p = page(Response.json({ sent: true }));
  await p.submit(); assert.equal(p.form.hidden, true); assert.equal(p.sent.hidden, false);
  assert.equal(p.requests, 1); assert.equal(p.timers.length, 0);
});
