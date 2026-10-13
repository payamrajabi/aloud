// /buy: starts a Stripe Checkout (Stripe is the merchant of record, so it handles sales tax
// and VAT) for whichever price ALOUD_PRICE_LOOKUP_KEY names, then sends the buyer there.
import { HttpError, SUPPORT_EMAIL, originOf, stripe } from './_lib.mjs';

export async function GET(request) {
  try {
    const lookupKey = process.env.ALOUD_PRICE_LOOKUP_KEY || 'aloud_launch';
    const prices = await stripe('/prices', { params: { lookup_keys: [lookupKey], active: true, limit: 1 } });
    const price = prices.data[0];
    if (!price) throw new HttpError(503, `No active Stripe price with lookup key ${lookupKey}.`);
    const origin = originOf(request);
    const session = await stripe('/checkout/sessions', {
      method: 'POST',
      params: {
        mode: 'payment',
        line_items: [{ price: price.id, quantity: 1 }],
        managed_payments: { enabled: true },
        metadata: { product: 'aloud' },
        success_url: `${origin}/thanks?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${origin}/#buy`,
      },
    });
    return Response.redirect(session.url, 303);
  } catch (error) {
    if (!(error instanceof HttpError)) console.error(error);
    const message = error instanceof HttpError ? error.message : 'Something went wrong.';
    return new Response(
      `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
      `<title>Aloud</title><body style="font:16px/1.5 -apple-system,sans-serif;max-width:32rem;margin:15vh auto;padding:0 16px">` +
      `<h1 style="font-size:22px">Checkout isn’t available right now</h1><p>${message} Please try again in a few minutes, ` +
      `or write to <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p><p><a href="/">Back to Aloud</a></p>`,
      { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } },
    );
  }
}
