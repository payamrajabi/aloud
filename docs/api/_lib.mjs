// No dependencies or server-side license store. Configure only after sandbox acceptance.
// ALOUD_PAYMENT_MODE defaults to test. Live also requires ALOUD_ENABLE_LIVE_PAYMENTS=true
// and VERCEL_ENV=production. STRIPE_SECRET_KEY must match that mode.
// SITE_ORIGIN is the exact HTTPS origin serving these routes (no trailing slash).
// LICENSE_SIGNING_KEY is an Ed25519 PEM; the release app has its public half.
// Email is disabled unless ALOUD_EMAIL_ENABLED=true, RESEND_API_KEY and LICENSE_EMAIL_FROM
// are configured. This does not authorize creating a Resend account or sending email.
import { createHmac, createPrivateKey, createPublicKey, sign, timingSafeEqual } from 'node:crypto';
export const STRIPE_API_VERSION = '2026-04-22.dahlia';

// Must match the fixed public key in Licensing.swift. Rotation requires an
// intentional app/backend release; request input and environment cannot override it.
export const RELEASE_LICENSE_PUBLIC_KEY_BASE64 = 'Jloz1nv3RGWcn3FDnpYmymCeF7fku8q9H3Rqx6giMp4=';
const RELEASE_LICENSE_PUBLIC_KEY = Buffer.from(RELEASE_LICENSE_PUBLIC_KEY_BASE64, 'base64');

export const validEmail = (value) => typeof value === 'string' && Buffer.byteLength(value, 'utf8') <= 254
  && !/[\p{Cc}\p{Cf}]/u.test(value)
  && /^[^@\s<>\x00-\x1f]+@[^@\s<>\x00-\x1f]+\.[^@\s<>\x00-\x1f]+$/.test(value);
export const SUPPORT_EMAIL = validEmail(process.env.SUPPORT_EMAIL)
  ? process.env.SUPPORT_EMAIL : 'payam.rajabi@gmail.com';

export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function paymentMode() {
  const mode = process.env.ALOUD_PAYMENT_MODE || 'test';
  if (!['test', 'live'].includes(mode)) throw new HttpError(503, 'Payment mode isn’t configured.');
  if (mode === 'live' && (process.env.ALOUD_ENABLE_LIVE_PAYMENTS !== 'true'
    || process.env.VERCEL_ENV !== 'production')) throw new HttpError(503, 'Live payments are disabled.');
  return mode;
}

function stripeKey() {
  const key = process.env.STRIPE_SECRET_KEY;
  if (typeof key !== 'string' || key !== key.trim()
    || !new RegExp(`^(?:sk|rk)_${paymentMode()}_[A-Za-z0-9]+$`).test(key) || key.length < 12) {
    throw new HttpError(503, 'Payments aren’t configured for this mode.');
  }
  return key;
}

export function requireStripeMode() { stripeKey(); return paymentMode(); }

/** Never derive redirects or activation links from Host / forwarded headers. */
export function originOf(request) {
  let configured;
  try { configured = new URL(process.env.SITE_ORIGIN); } catch {
    throw new HttpError(503, 'The payment site isn’t configured.');
  }
  if (configured.protocol !== 'https:' || configured.username || configured.password
    || configured.origin !== process.env.SITE_ORIGIN) throw new HttpError(503, 'The payment site isn’t configured.');
  if (request && new URL(request.url).origin !== configured.origin) {
    throw new HttpError(400, 'This payment request used the wrong site.');
  }
  return configured.origin;
}

function signingKey() {
  try {
    const pem = process.env.LICENSE_SIGNING_KEY;
    if (!pem) throw new Error();
    const key = createPrivateKey(pem.replace(/\\n/g, '\n'));
    if (key.asymmetricKeyType !== 'ed25519') throw new Error();
    return key;
  } catch { throw new HttpError(503, 'License signing isn’t configured.'); }
}

/** Pure licenseFor remains usable by offline test harnesses. HTTP live fulfillment
 * must also prove its signer can unlock the released app before accepting money.
 */
export function assertReleaseSigner() {
  if (paymentMode() !== 'live') return;
  const publicDER = createPublicKey(signingKey()).export({ format: 'der', type: 'spki' });
  if (!publicDER.subarray(-32).equals(RELEASE_LICENSE_PUBLIC_KEY)) {
    throw new HttpError(503, 'License signing doesn’t match the released app.');
  }
}

export function requireEmail() {
  const from = process.env.LICENSE_EMAIL_FROM;
  const address = typeof from === 'string' ? (from.match(/^[^<>\r\n]+ <([^<>]+)>$/)?.[1] || from) : '';
  if (process.env.ALOUD_EMAIL_ENABLED !== 'true' || !process.env.RESEND_API_KEY
    || !validEmail(address)) throw new HttpError(503, 'License email isn’t configured.');
  if (paymentMode() === 'test') testEmailRecipients();
}

/** No implicit sandbox recipient, wildcard, or request-controlled override. */
function testEmailRecipients() {
  const configured = process.env.ALOUD_TEST_EMAIL_ALLOWLIST;
  if (typeof configured !== 'string' || Buffer.byteLength(configured, 'utf8') > 8192
    || /[\p{Cc}\p{Cf}]/u.test(configured)) {
    throw new HttpError(503, 'Sandbox email recipients aren’t configured.');
  }
  const addresses = configured.split(',').map(address => address.trim());
  if (!addresses.length || addresses.length > 20
    || addresses.some(address => !validEmail(address) || address.includes('*'))) {
    throw new HttpError(503, 'Sandbox email recipients aren’t configured.');
  }
  return new Set(addresses.map(address => address.toLowerCase()));
}

export function requireEmailRecipient(email) {
  if (!validEmail(email)) throw new HttpError(400, 'License email recipient is invalid.');
  if (paymentMode() === 'test' && !testEmailRecipients().has(email.toLowerCase())) {
    throw new HttpError(403, 'Sandbox email recipient is not approved.');
  }
}

export function requireDelivery(request) {
  const origin = originOf(request);
  stripeKey(); signingKey(); assertReleaseSigner(); requireEmail();
  return origin;
}

/** Checkout must not accept money before its fulfillment path is ready. */
export function requireCheckout(request) {
  const origin = requireDelivery(request);
  if (!/^whsec_[^\s]+$/.test(process.env.STRIPE_WEBHOOK_SECRET || '')) {
    throw new HttpError(503, 'Webhook verification isn’t configured.');
  }
  return origin;
}

function formEncode(params, prefix, out = new URLSearchParams()) {
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null) continue;
    const name = prefix ? `${prefix}[${key}]` : key;
    if (typeof value === 'object') formEncode(value, name, out);
    else out.append(name, String(value));
  }
  return out;
}

export async function stripe(path, { method = 'GET', params, idempotencyKey } = {}) {
  const key = stripeKey();
  const query = params ? formEncode(params) : null;
  let res, data;
  try {
    res = await fetch(`https://api.stripe.com/v1${path}${method === 'GET' && query ? `?${query}` : ''}`, {
      method,
      headers: { Authorization: `Bearer ${key}`, 'Stripe-Version': STRIPE_API_VERSION,
        ...(method === 'GET' ? {} : { 'Content-Type': 'application/x-www-form-urlencoded',
          ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) }) },
      body: method === 'GET' ? undefined : query,
      signal: AbortSignal.timeout(15_000),
    });
    data = await res.json();
  } catch { throw new HttpError(502, 'The payment service is temporarily unavailable.'); }
  if (!res.ok) throw new HttpError(res.status === 404 ? 404 : 502, 'The payment service didn’t answer as expected.');
  return data;
}

export function assertSessionMode(session) {
  const mode = paymentMode();
  if (session?.object !== 'checkout.session' || session.livemode !== (mode === 'live')
    || typeof session.id !== 'string' || !new RegExp(`^cs_${mode}_[A-Za-z0-9]+$`).test(session.id)) {
    throw new HttpError(400, 'The checkout doesn’t match this payment mode.');
  }
  return mode;
}

export function isPaidAloud(session) {
  try { assertSessionMode(session); } catch { return false; }
  return session.metadata?.product === 'aloud' && session.mode === 'payment'
    && session.status === 'complete' && session.payment_status === 'paid'
    && validEmail(session.customer_details?.email)
    && Number.isSafeInteger(session.created) && session.created > 0
    && session.created <= Math.floor(Date.now() / 1000) + 300;
}

/** Explicit immutable price IDs preserve approved historical purchases even after
 * a lookup key moves or a price is archived. No configured IDs means no sales.
 */
export function approvedPurchasePolicy() {
  const raw = process.env.ALOUD_APPROVED_PRICE_IDS;
  const prices = typeof raw === 'string' ? raw.split(',').map(id => id.trim()) : [];
  if (!prices.length || prices.some(id => !/^price_[A-Za-z0-9]+$/.test(id))) {
    throw new HttpError(503, 'Approved Aloud prices aren’t configured.');
  }
  return { product: process.env.ALOUD_STRIPE_PRODUCT_ID || 'aloud', prices: new Set(prices) };
}

/** The returned field is documented in 2026-04-22.dahlia. Never infer coverage
 * from metadata, taxes, Link usage, or our enabled:true creation request alone.
 */
export function assertManagedPayments(session) {
  if (session?.managed_payments?.enabled !== true) {
    throw new HttpError(503, 'Managed Payments coverage couldn’t be verified.');
  }
}

/** Call only with a session read from Stripe using this deployment's scoped key.
 * The signed event and mutable product metadata are insufficient purchase proof.
 */
export async function verifyPurchase(session) {
  const policy = approvedPurchasePolicy();
  if (!isPaidAloud(session)) throw new HttpError(404, 'No completed Aloud purchase found.');
  if (session.managed_payments?.enabled !== true) throw new HttpError(404, 'No approved Managed Payments purchase found.');
  const lines = await stripe(`/checkout/sessions/${session.id}/line_items`, { params: { limit: 2 } });
  const item = lines?.data?.[0];
  const priceId = typeof item?.price === 'string' ? item.price : item?.price?.id;
  if (lines?.object !== 'list' || lines.has_more !== false || !Array.isArray(lines.data)
    || lines.data.length !== 1 || item.object !== 'item' || item.quantity !== 1
    || !policy.prices.has(priceId)) throw new HttpError(404, 'No approved Aloud purchase found.');
  const price = await stripe(`/prices/${priceId}`, { params: { expand: ['currency_options'] } });
  const currency = session.currency;
  const amount = price?.currency === currency ? price.unit_amount : price?.currency_options?.[currency]?.unit_amount;
  if (price?.object !== 'price' || price.id !== priceId || price.type !== 'one_time'
    || price.recurring != null || price.custom_unit_amount != null || price.transform_quantity != null
    || price.billing_scheme !== 'per_unit' || (price.product?.id || price.product) !== policy.product
    || price.livemode !== (paymentMode() === 'live')
    || !/^[a-z]{3}$/.test(currency || '') || item.currency !== currency
    || !Number.isSafeInteger(amount) || amount <= 0
    || !Number.isSafeInteger(item.amount_subtotal) || item.amount_subtotal !== amount
    || !Number.isSafeInteger(item.amount_total) || item.amount_total <= 0
    || !Number.isSafeInteger(session.amount_subtotal) || session.amount_subtotal !== item.amount_subtotal
    || !Number.isSafeInteger(session.amount_total) || session.amount_total !== item.amount_total) {
    throw new HttpError(404, 'No approved Aloud purchase found.');
  }
  return session;
}

export async function retrievePurchase(id) {
  const mode = paymentMode();
  if (typeof id !== 'string' || !new RegExp(`^cs_${mode}_[A-Za-z0-9]+$`).test(id)) {
    throw new HttpError(400, 'That isn’t a checkout link for this mode.');
  }
  approvedPurchasePolicy();
  const session = await stripe(`/checkout/sessions/${id}`);
  assertSessionMode(session);
  if (session.id !== id) throw new HttpError(404, 'No completed Aloud purchase found.');
  return verifyPurchase(session);
}

export function licenseFor(session) {
  const mode = assertSessionMode(session);
  if (!isPaidAloud(session)) throw new HttpError(400, 'No completed Aloud purchase found.');
  const payload = Buffer.from(JSON.stringify({ product: 'aloud', mode,
    email: session.customer_details.email, id: session.id,
    issued: new Date(session.created * 1000).toISOString().slice(0, 10) }));
  const signature = sign(null, payload, signingKey());
  return `${payload.toString('base64url')}.${signature.toString('base64url')}`;
}

/** Raw-body verification; supports rotated v1 signatures, rejects ambiguous timestamps. */
export function verifyStripeSignature(body, header, secret) {
  if (!secret) throw new HttpError(503, 'Webhook verification isn’t configured.');
  const parts = (header || '').split(',').map((part) => part.trim());
  const timestamps = parts.filter((part) => part.startsWith('t='));
  const timestamp = timestamps.length === 1 && /^t=\d+$/.test(timestamps[0])
    ? Number(timestamps[0].slice(2)) : 0;
  if (!Number.isSafeInteger(timestamp) || timestamp <= 0 || Math.abs(Date.now() / 1000 - timestamp) > 300) {
    throw new HttpError(400, 'Stale or missing signature.');
  }
  const expected = createHmac('sha256', secret).update(`${timestamp}.${body}`).digest();
  const valid = parts.filter((part) => /^v1=[a-fA-F0-9]{64}$/.test(part)).some((part) =>
    timingSafeEqual(Buffer.from(part.slice(3), 'hex'), expected));
  if (!valid) throw new HttpError(400, 'Bad signature.');
}

export const escapeHTML = (value) => String(value).replace(/[&<>"']/g, (char) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);

/** Resend deduplicates identical keys for 24h, including across cold starts.
 * Purchase keys belong to the session, not the event; webhook.mjs adds durable
 * attempt/acceptance markers. Restore allows one new send per hour.
 */
export async function emailLicense(session, origin, purpose = 'purchase') {
  requireEmail();
  assertReleaseSigner();
  if (origin !== originOf()) throw new HttpError(503, 'The payment site isn’t configured.');
  const license = licenseFor(session);
  requireEmailRecipient(session.customer_details.email);
  const link = `${origin}/activate#${license}`;
  const text = ['Thanks for buying Aloud!', '', `Unlock Aloud on this Mac: ${link}`, '',
    'Or open Aloud Settings → License → Enter License… and paste:', '', license, '',
    'It works on all your Macs. Keep this email to unlock Aloud again on a new Mac.',
    `Questions? Just reply, or write to ${SUPPORT_EMAIL}.`].join('\n');
  const html = `<p>Thanks for buying Aloud!</p><p><a href="${escapeHTML(link)}">Unlock Aloud on this Mac</a></p>`
    + `<p>Or paste this in Aloud Settings → License → Enter License…:</p><p>${escapeHTML(license)}</p>`
    + '<p>It works on all your Macs. Keep this email to unlock Aloud again. Questions? Just reply.</p>';
  const suffix = purpose === 'restore' ? `/restore/${Math.floor(Date.now() / 3_600_000)}` : '/purchase';
  let res;
  try {
    res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'Content-Type': 'application/json',
        'Idempotency-Key': `aloud/${paymentMode()}/${session.id}${suffix}` },
      body: JSON.stringify({ from: process.env.LICENSE_EMAIL_FROM, to: [session.customer_details.email],
        reply_to: SUPPORT_EMAIL, subject: 'Your Aloud license', text, html }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch { throw new HttpError(502, 'License email is temporarily unavailable.'); }
  if (!res.ok) throw new HttpError(502, 'License email is temporarily unavailable.');
  return true;
}

export const json = (body, status = 200) => Response.json(body, {
  status, headers: { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } });

export function fail(error) {
  // Provider exceptions can contain credentials, licenses and buyer details. Never log them.
  if (!(error instanceof HttpError)) console.error('Payment request failed.');
  return json({ error: error instanceof HttpError ? error.message : 'Something went wrong.',
    support: SUPPORT_EMAIL }, error instanceof HttpError ? error.status : 500);
}
