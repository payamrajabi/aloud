// /api/webhook: Stripe calls this when a purchase completes, and we email the license.
// Stripe retries on any non-2xx, so a failed email is retried too.
import { emailLicense, fail, isPaidAloud, json, originOf, verifyStripeSignature } from './_lib.mjs';

const HANDLED = new Set(['checkout.session.completed', 'checkout.session.async_payment_succeeded']);

export async function POST(request) {
  try {
    const body = await request.text();
    verifyStripeSignature(body, request.headers.get('stripe-signature'), process.env.STRIPE_WEBHOOK_SECRET);
    const event = JSON.parse(body);
    const session = event.data?.object;
    if (HANDLED.has(event.type) && isPaidAloud(session)) {
      await emailLicense(session, process.env.SITE_ORIGIN || originOf(request));
    }
    return json({ received: true });
  } catch (error) {
    return fail(error);
  }
}
