// Shared by the payment functions. No dependencies: Stripe and Resend are called with fetch,
// and licenses are signed with Node's built-in Ed25519.
//
// Environment (Vercel project settings):
//   STRIPE_SECRET_KEY        sk_live_… (or sk_test_… on previews)
//   STRIPE_WEBHOOK_SECRET    whsec_… for /api/webhook
//   LICENSE_SIGNING_KEY      Ed25519 private key (PEM). The app has the public half built in.
//   ALOUD_PRICE_LOOKUP_KEY   which Stripe price /buy sells: aloud_launch ($9.99) or aloud_regular ($19)
//   RESEND_API_KEY           sends the license email (optional; without it, only the thank-you page has it)
//   LICENSE_EMAIL_FROM       e.g. "Aloud <hello@aloudformac.com>" (a domain verified in Resend)
//   SUPPORT_EMAIL            reply-to address on license emails
import { createHmac, createPrivateKey, sign, timingSafeEqual } from 'node:crypto';

export const SUPPORT_EMAIL = process.env.SUPPORT_EMAIL || 'hello@aloudformac.com';

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// MARK: Stripe

/** Stripe's form encoding: {a: [{b: 1}]} → a[0][b]=1. */
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
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw new HttpError(503, 'Payments aren’t set up yet.');
  const query = params ? formEncode(params) : null;
  const url = `https://api.stripe.com/v1${path}${method === 'GET' && query ? `?${query}` : ''}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${key}`,
      'Stripe-Version': '2025-09-30.clover',
      ...(method === 'GET' ? {} : { 'Content-Type': 'application/x-www-form-urlencoded' }),
    },
    body: method === 'GET' ? undefined : query,
  });
  const json = await res.json();
  if (!res.ok) {
    console.error(`Stripe ${method} ${path} failed:`, json.error?.message);
    throw new HttpError(res.status === 404 ? 404 : 502, 'The payment service didn’t answer as expected.');
  }
  return json;
}

/** Checks the Stripe-Signature header: HMAC-SHA256 of "timestamp.body", within 5 minutes. */
export function verifyStripeSignature(body, header, secret) {
  if (!secret) throw new HttpError(503, 'Webhook secret isn’t set.');
  const parts = Object.groupBy((header || '').split(','), (part) => part.split('=')[0]);
  const timestamp = Number(parts.t?.[0]?.slice(2));
  if (!timestamp || Math.abs(Date.now() / 1000 - timestamp) > 300) throw new HttpError(400, 'Stale or missing signature.');
  const expected = Buffer.from(createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex'));
  const valid = (parts.v1 || []).some((part) => {
    const given = Buffer.from(part.slice(3));
    return given.length === expected.length && timingSafeEqual(given, expected);
  });
  if (!valid) throw new HttpError(400, 'Bad signature.');
}

/** A completed, paid Checkout Session for Aloud (async payment methods can complete before they're paid). */
export function isPaidAloud(session) {
  return session?.metadata?.product === 'aloud' && session.payment_status === 'paid';
}

// MARK: Licenses

const base64url = (buffer) => Buffer.from(buffer).toString('base64url');

/**
 * base64url(JSON) + "." + base64url(Ed25519 signature). Ed25519 is deterministic, so the
 * same purchase always yields the same license: nothing needs storing.
 */
export function licenseFor(session) {
  const pem = process.env.LICENSE_SIGNING_KEY;
  if (!pem) throw new HttpError(503, 'License signing isn’t set up yet.');
  const payload = Buffer.from(JSON.stringify({
    product: 'aloud',
    email: session.customer_details?.email || '',
    id: session.id,
    issued: new Date(session.created * 1000).toISOString().slice(0, 10),
  }));
  const signature = sign(null, payload, createPrivateKey(pem.replace(/\\n/g, '\n')));
  return `${base64url(payload)}.${base64url(signature)}`;
}

// MARK: Email

export async function emailLicense(session, origin) {
  const key = process.env.RESEND_API_KEY;
  const to = session.customer_details?.email;
  if (!key || !to) {
    console.warn('License email skipped:', key ? 'no customer email' : 'RESEND_API_KEY not set');
    return false;
  }
  const license = licenseFor(session);
  const link = `${origin}/activate#${license}`;
  const text = [
    'Thanks for buying Aloud!',
    '',
    `Unlock Aloud on this Mac: ${link}`,
    '',
    'Or open Aloud Settings → License → Enter License… and paste:',
    '',
    license,
    '',
    'It works on all your Macs. Keep this email to unlock Aloud again on a new Mac.',
    `Questions? Just reply, or write to ${SUPPORT_EMAIL}.`,
  ].join('\n');
  const html = `<div style="font:15px/1.5 -apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;color:#1d1d1f;max-width:520px">
<p>Thanks for buying Aloud!</p>
<p><a href="${link}" style="display:inline-block;background:#1d1d1f;color:#fff;text-decoration:none;padding:10px 18px;border-radius:999px;font-weight:600">Unlock Aloud on this Mac</a></p>
<p>Or open Aloud Settings → License → Enter License… and paste:</p>
<p style="font:12px/1.4 ui-monospace,Menlo,monospace;word-break:break-all;background:#f5f5f7;padding:10px 12px;border-radius:8px">${license}</p>
<p style="color:#6e6e73">It works on all your Macs. Keep this email to unlock Aloud again on a new Mac. Questions? Just reply.</p>
</div>`;
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: process.env.LICENSE_EMAIL_FROM || 'Aloud <hello@aloudformac.com>',
      to: [to],
      reply_to: SUPPORT_EMAIL,
      subject: 'Your Aloud license',
      text,
      html,
    }),
  });
  if (!res.ok) throw new Error(`Resend failed: ${res.status} ${await res.text()}`);
  return true;
}

// MARK: Responses

export const json = (body, status = 200) =>
  Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });

export function fail(error) {
  if (!(error instanceof HttpError)) console.error(error);
  const status = error instanceof HttpError ? error.status : 500;
  const message = error instanceof HttpError ? error.message : 'Something went wrong.';
  return json({ error: message, support: SUPPORT_EMAIL }, status);
}

export const originOf = (request) => new URL(request.url).origin;
