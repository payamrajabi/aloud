// /api/restore: "find my license". Emails the license to the address that bought it, so the
// answer is the same whether or not that address has bought Aloud.
import { HttpError, emailLicense, fail, isPaidAloud, json, originOf, stripe } from './_lib.mjs';

export async function POST(request) {
  try {
    const form = await request.formData().catch(() => null);
    const email = String(form?.get('email') || '').trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new HttpError(400, 'Enter the email address you bought Aloud with.');
    if (!process.env.RESEND_API_KEY) throw new HttpError(503, 'Email isn’t set up yet.');
    // Stripe matches the address exactly, so try it as typed and in lower case.
    let purchase;
    for (const address of new Set([email, email.toLowerCase()])) {
      const sessions = await stripe('/checkout/sessions', {
        params: { customer_details: { email: address }, status: 'complete', limit: 20 },
      });
      purchase = sessions.data.find(isPaidAloud);
      if (purchase) break;
    }
    if (purchase) await emailLicense(purchase, process.env.SITE_ORIGIN || originOf(request));
    return json({ sent: true });
  } catch (error) {
    return fail(error);
  }
}
