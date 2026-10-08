// /api/license?session_id=cs_…: the thank-you page swaps a finished Checkout for the license,
// so the app unlocks straight away without waiting for the email.
import { HttpError, fail, isPaidAloud, json, licenseFor, stripe } from './_lib.mjs';

export async function GET(request) {
  try {
    const id = new URL(request.url).searchParams.get('session_id') || '';
    if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(id)) throw new HttpError(400, 'That isn’t a checkout link.');
    const session = await stripe(`/checkout/sessions/${id}`);
    if (session.metadata?.product !== 'aloud') throw new HttpError(404, 'No Aloud purchase found.');
    // Bank transfers and the like finish later; the page asks again, and the email follows when it's paid.
    if (!isPaidAloud(session)) return json({ pending: true }, 202);
    return json({ license: licenseFor(session), email: session.customer_details?.email || '' });
  } catch (error) {
    return fail(error);
  }
}
