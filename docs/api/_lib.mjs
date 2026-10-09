// No dependencies or server-side license store. Configure only after sandbox acceptance.
// ALOUD_PAYMENT_MODE defaults to test. Live also requires ALOUD_ENABLE_LIVE_PAYMENTS=true
// and VERCEL_ENV=production. STRIPE_SECRET_KEY must match that mode.
// SITE_ORIGIN is the exact HTTPS origin serving these routes (no trailing slash).
// LICENSE_SIGNING_KEY is an Ed25519 PEM; the release app has its public half.
// Email is disabled unless ALOUD_EMAIL_ENABLED=true, RESEND_API_KEY and LICENSE_EMAIL_FROM
// are configured. This does not authorize creating a Resend account or sending email.
import { createHmac, createPrivateKey, sign, timingSafeEqual } from 'node:crypto';

export const validEmail = (value) => typeof value === 'string' && Buffer.byteLength(value, 'utf8') <= 254
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
  if (typeof key !== 'string' || !key.startsWith(`sk_${paymentMode()}_`) || key.length < 12) {
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

export function requireEmail() {
  const from = process.env.LICENSE_EMAIL_FROM;
  const address = typeof from === 'string' ? (from.match(/^[^<>\r\n]+ <([^<>]+)>$/)?.[1] || from) : '';
  if (process.env.ALOUD_EMAIL_ENABLED !== 'true' || !process.env.RESEND_API_KEY
    || !validEmail(address)) throw new HttpError(503, 'License email isn’t configured.');
}

export function requireDelivery(request) {
  const origin = originOf(request);
  stripeKey(); signingKey(); requireEmail();
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

export async function stripe(path, { method = 'GET', params } = {}) {
  const key = stripeKey();
  const query = params ? formEncode(params) : null;
  let res, data;
  try {
    res = await fetch(`https://api.stripe.com/v1${path}${method === 'GET' && query ? `?${query}` : ''}`, {
      method,
      headers: { Authorization: `Bearer ${key}`, 'Stripe-Version': '2025-09-30.clover',
        ...(method === 'GET' ? {} : { 'Content-Type': 'application/x-www-form-urlencoded' }) },
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
 * Purchase keys belong to the session, not the event. Later replays can email again:
 * this is not durable deduplication after 24h. Restore allows one new send per hour.
 */
export async function emailLicense(session, origin, purpose = 'purchase') {
  requireEmail();
  if (origin !== originOf()) throw new HttpError(503, 'The payment site isn’t configured.');
  const license = licenseFor(session);
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
