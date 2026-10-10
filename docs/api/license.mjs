import { HttpError, approvedPurchasePolicy, assertReleaseSigner, assertSessionMode, fail, isPaidAloud, json, licenseFor, originOf, paymentMode, stripe, verifyPurchase } from './_lib.mjs';

export async function GET(request) {
  try {
    originOf(request);
    const mode = paymentMode();
    assertReleaseSigner();
    const id = new URL(request.url).searchParams.get('session_id') || '';
    if (!new RegExp(`^cs_${mode}_[A-Za-z0-9]+$`).test(id)) throw new HttpError(400, 'That isn’t a checkout link for this mode.');
    approvedPurchasePolicy();
    const session = await stripe(`/checkout/sessions/${id}`);
    assertSessionMode(session);
    if (session.id !== id || session.metadata?.product !== 'aloud' || session.mode !== 'payment'
      || session.status !== 'complete') throw new HttpError(404, 'No completed Aloud purchase found.');
    if (session.payment_status === 'unpaid') return json({ pending: true, mode }, 202);
    if (!isPaidAloud(session)) throw new HttpError(404, 'No completed Aloud purchase found.');
    await verifyPurchase(session);
    return json({ license: licenseFor(session), email: session.customer_details.email, mode });
  } catch (error) { return fail(error); }
}
