import { HttpError, assertManagedPayments, assertSessionMode, emailLicense, fail, isPaidAloud, json, originOf, paymentMode, requireDelivery, requireEmailRecipient, requireStripeMode, retrievePurchase, stripe, verifyStripeSignature } from './_lib.mjs';

const HANDLED = new Set(['checkout.session.completed', 'checkout.session.async_payment_succeeded']);
const EMAIL_RETRY_WINDOW = 23 * 3600; // Stay inside Resend's 24-hour retention.

async function deliverPurchaseOnce(session, origin) {
  requireEmailRecipient(session.customer_details.email);
  const metadata = session.metadata;
  const rawAttempt = metadata.aloud_email_attempt_at;
  const accepted = metadata.aloud_email_accepted;
  const now = Math.floor(Date.now() / 1000);
  let attempted;
  if (rawAttempt !== undefined) {
    attempted = typeof rawAttempt === 'string' && /^\d+$/.test(rawAttempt) ? Number(rawAttempt) : NaN;
    if (!Number.isSafeInteger(attempted) || String(attempted) !== rawAttempt
      || attempted < session.created || attempted > now) {
      throw new HttpError(503, 'Purchase email needs manual reconciliation.');
    }
  }
  if (accepted !== undefined) {
    if (accepted !== 'v1' || attempted === undefined) throw new HttpError(503, 'Purchase email needs manual reconciliation.');
    return; // Durable acknowledgement of provider acceptance; never automatically resend.
  }
  if (attempted !== undefined && now - attempted >= EMAIL_RETRY_WINDOW) {
    throw new HttpError(503, 'Purchase email needs manual reconciliation.');
  }
  const key = `aloud/${paymentMode()}/${session.id}`;
  if (attempted === undefined) {
    attempted = now;
    const stored = await stripe(`/checkout/sessions/${session.id}`, { method: 'POST',
      params: { metadata: { aloud_email_attempt_at: String(attempted) } }, idempotencyKey: `${key}/email-attempt-v1` });
    assertSessionMode(stored); assertManagedPayments(stored);
    if (stored.id !== session.id || stored.metadata?.aloud_email_attempt_at !== String(attempted)) {
      throw new HttpError(502, 'Purchase email state couldn’t be saved.');
    }
  }
  await emailLicense(session, origin);
  const stored = await stripe(`/checkout/sessions/${session.id}`, { method: 'POST',
    params: { metadata: { aloud_email_accepted: 'v1' } }, idempotencyKey: `${key}/email-accepted-v1` });
  assertSessionMode(stored); assertManagedPayments(stored);
  if (stored.id !== session.id || stored.metadata?.aloud_email_accepted !== 'v1'
    || stored.metadata?.aloud_email_attempt_at !== String(attempted)) {
    throw new HttpError(502, 'Purchase email state couldn’t be saved.');
  }
}

export async function POST(request) {
  try {
    const origin = originOf(request);
    const mode = requireStripeMode();
    const body = await request.text();
    verifyStripeSignature(body, request.headers.get('stripe-signature'), process.env.STRIPE_WEBHOOK_SECRET);
    let event;
    try { event = JSON.parse(body); } catch { throw new HttpError(400, 'Invalid webhook payload.'); }
    if (event?.object !== 'event' || !/^evt_[A-Za-z0-9]+$/.test(event.id || '')
      || typeof event.type !== 'string' || event.livemode !== (mode === 'live')) {
      throw new HttpError(400, 'The event doesn’t match this payment mode.');
    }
    if (HANDLED.has(event.type)) {
      if (event.account || event.context) throw new HttpError(400, 'Connected or organization payment events aren’t supported.');
      const session = event.data?.object;
      assertSessionMode(session);
      // Ignore unrelated products and completed-but-unpaid async checkouts.
      if (session.metadata?.product === 'aloud') {
        if (session.mode !== 'payment' || session.status !== 'complete') throw new HttpError(400, 'Invalid Aloud purchase.');
        if (session.payment_status === 'paid') {
          if (!isPaidAloud(session)) throw new HttpError(400, 'Invalid Aloud purchase.');
          requireDelivery(request);
          const purchase = await retrievePurchase(session.id);
          await deliverPurchaseOnce(purchase, origin);
        }
      }
    }
    return json({ received: true, mode });
  } catch (error) { return fail(error); }
}
