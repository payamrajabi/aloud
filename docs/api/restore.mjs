import { HttpError, approvedPurchasePolicy, emailLicense, fail, isPaidAloud, json, requireDelivery, retrievePurchase, stripe, validEmail } from './_lib.mjs';

export async function POST(request) {
  try {
    // Operator attestation after approved platform protection is verified, not proof
    // that a WAF rule is active. Request headers/body cannot opt into provider calls.
    if (process.env.ALOUD_RESTORE_PROTECTION_READY !== 'true') {
      throw new HttpError(503, 'License recovery isn’t available yet. Contact support for help.');
    }
    const origin = requireDelivery(request);
    approvedPurchasePolicy();
    const form = await request.formData().catch(() => null);
    const email = String(form?.get('email') || '').trim();
    if (!validEmail(email)) throw new HttpError(400, 'Enter the email address you bought Aloud with.');
    try {
      let purchase, checked = 0;
      for (const address of new Set([email, email.toLowerCase()])) {
        let cursor;
        // Filter in Stripe, verify the returned address locally, and paginate older purchases.
        for (let page = 0; page < 100; page++) {
          const sessions = await stripe('/checkout/sessions', { params: {
            customer_details: { email: address }, status: 'complete', limit: 100, starting_after: cursor,
          } });
          if (!Array.isArray(sessions.data)) throw new HttpError(502, 'Purchase lookup unavailable.');
          for (const candidate of sessions.data) {
            if (!isPaidAloud(candidate) || candidate.customer_details.email.toLowerCase() !== email.toLowerCase()) continue;
            if (++checked > 100) throw new HttpError(502, 'Purchase lookup unavailable.');
            try {
              const verified = await retrievePurchase(candidate.id);
              // Re-check the canonical recipient, never trust the list or event address.
              if (verified.customer_details.email.toLowerCase() === email.toLowerCase()) { purchase = verified; break; }
            } catch (error) {
              if (!(error instanceof HttpError) || error.status !== 404) throw error;
            }
          }
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
