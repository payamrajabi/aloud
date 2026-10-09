import { HttpError, SUPPORT_EMAIL, approvedPurchasePolicy, assertManagedPayments, assertSessionMode, escapeHTML, requireCheckout, stripe } from './_lib.mjs';

export async function GET(request) {
  try {
    const origin = requireCheckout(request);
    const policy = approvedPurchasePolicy();
    const lookupKey = process.env.ALOUD_PRICE_LOOKUP_KEY || 'aloud_launch';
    const prices = await stripe('/prices', { params: { lookup_keys: [lookupKey], active: true, limit: 1 } });
    const price = prices.data?.[0];
    if (!price || price.object !== 'price' || price.active !== true || price.type !== 'one_time'
      || price.billing_scheme !== 'per_unit' || price.recurring != null
      || price.custom_unit_amount != null || price.transform_quantity != null
      || !/^[a-z]{3}$/.test(price.currency || '')
      || !policy.prices.has(price.id) || (price.product?.id || price.product) !== policy.product || price.lookup_key !== lookupKey
      || price.livemode !== (process.env.ALOUD_PAYMENT_MODE === 'live')
      || !Number.isSafeInteger(price.unit_amount) || price.unit_amount <= 0) {
      throw new HttpError(503, 'An Aloud purchase price isn’t configured for this mode.');
    }
    const session = await stripe('/checkout/sessions', { method: 'POST', params: {
      mode: 'payment', line_items: [{ price: price.id, quantity: 1 }], managed_payments: { enabled: true },
      metadata: { product: 'aloud' }, success_url: `${origin}/thanks?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/#buy`,
    } });
    assertSessionMode(session);
    assertManagedPayments(session);
    let checkout;
    try { checkout = new URL(session.url); } catch { throw new HttpError(502, 'The checkout link wasn’t valid.'); }
    if (session.mode !== 'payment' || session.status !== 'open' || session.metadata?.product !== 'aloud'
      || checkout.protocol !== 'https:' || checkout.hostname !== 'checkout.stripe.com'
      || checkout.username || checkout.password || checkout.port) throw new HttpError(502, 'The checkout link wasn’t valid.');
    return new Response(null, { status: 303, headers: { Location: checkout.href, 'Cache-Control': 'no-store' } });
  } catch (error) {
    if (!(error instanceof HttpError)) console.error('Checkout request failed.');
    const message = error instanceof HttpError ? error.message : 'Something went wrong.';
    return new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
      + '<title>Aloud</title><h1>Checkout isn’t available right now</h1>'
      + `<p>${escapeHTML(message)} Please try again, or write to <a href="mailto:${escapeHTML(SUPPORT_EMAIL)}">`
      + `${escapeHTML(SUPPORT_EMAIL)}</a>.</p><p><a href="/">Back to Aloud</a></p>`,
    { status: error instanceof HttpError && error.status === 400 ? 400 : 503,
      headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
  }
}
