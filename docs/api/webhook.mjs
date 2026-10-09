import { HttpError, assertSessionMode, emailLicense, fail, isPaidAloud, json, originOf, requireStripeMode, verifyStripeSignature } from './_lib.mjs';

const HANDLED = new Set(['checkout.session.completed', 'checkout.session.async_payment_succeeded']);

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
      const session = event.data?.object;
      assertSessionMode(session);
      // Ignore unrelated products and completed-but-unpaid async checkouts.
      if (session.metadata?.product === 'aloud') {
        if (session.mode !== 'payment' || session.status !== 'complete') throw new HttpError(400, 'Invalid Aloud purchase.');
        if (session.payment_status === 'paid') {
          if (!isPaidAloud(session)) throw new HttpError(400, 'Invalid Aloud purchase.');
          await emailLicense(session, origin);
        }
      }
    }
    return json({ received: true, mode });
  } catch (error) { return fail(error); }
}
