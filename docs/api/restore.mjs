import { HttpError, emailLicense, fail, isPaidAloud, json, requireDelivery, stripe, validEmail } from './_lib.mjs';

export async function POST(request) {
  try {
    // Operator attestation after approved platform protection is verified, not proof
    // that a WAF rule is active. Request headers/body cannot opt into provider calls.
    if (process.env.ALOUD_RESTORE_PROTECTION_READY !== 'true') {
      throw new HttpError(503, 'License recovery isn’t available yet. Contact support for help.');
    }
    const origin = requireDelivery(request);
    const form = await request.formData().catch(() => null);
    const email = String(form?.get('email') || '').trim();
    if (!validEmail(email)) throw new HttpError(400, 'Enter the email address you bought Aloud with.');
    try {
      let purchase;
      for (const address of new Set([email, email.toLowerCase()])) {
        let cursor;
        // Filter in Stripe, verify the returned address locally, and paginate older purchases.
        for (let page = 0; page < 100; page++) {
          const sessions = await stripe('/checkout/sessions', { params: {
            customer_details: { email: address }, status: 'complete', limit: 100, starting_after: cursor,
          } });
          if (!Array.isArray(sessions.data)) throw new HttpError(502, 'Purchase lookup unavailable.');
          purchase = sessions.data.find((session) => isPaidAloud(session)
            && session.customer_details.email.toLowerCase() === email.toLowerCase());
          if (purchase || !sessions.has_more) break;
          const next = sessions.data.at(-1)?.id;
          if (!next || next === cursor || page === 99) throw new HttpError(502, 'Purchase lookup unavailable.');
          cursor = next;
        }
        if (purchase) break;
      }
      if (purchase) await emailLicense(purchase, origin, 'restore');
    } catch {
      // Identical public result for buyers, unknown addresses and delivery failures.
      console.error('License restore lookup or delivery failed.');
    }
    return json({ sent: true });
  } catch (error) { return fail(error); }
}
