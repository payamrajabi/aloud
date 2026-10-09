import { pathToFileURL } from 'node:url';

export const setupPlan = {
  mode: 'test',
  product: { id: 'aloud', name: 'Aloud', tax_code: 'txcd_10202000' },
  prices: [
    { lookup_key: 'aloud_launch', usd: 999, cad: 999 },
    { lookup_key: 'aloud_regular', usd: 1900, cad: 1900, eur: 1900, gbp: 1700, aud: 2900 },
  ],
  webhook: { path: '/api/webhook', events: ['checkout.session.completed', 'checkout.session.async_payment_succeeded'] },
  ownerSteps: [
    'Complete physical-ID verification and obtain Managed Payments approval.',
    'Approve separate test-only credentials and a license signing key/public-key pair.',
    'Approve email delivery configuration; no new provider subscription is included.',
    'Create test product/prices and webhook only after reviewing the plan and authorizing setup.',
    'Confirm regional launch amounts before adding them; only USD/CAD launch amounts are specified here.',
  ],
};

export async function inspectTestAccount({ key, siteOrigin, fetcher = fetch }) {
  if (!/^sk_test_[A-Za-z0-9]+$/.test(key || '')) throw new Error('Use an authorized Stripe test secret key; live keys are rejected.');
  if (siteOrigin) {
    let url;
    try { url = new URL(siteOrigin); } catch { throw new Error('Use an exact HTTPS SITE_ORIGIN.'); }
    if (url.protocol !== 'https:' || url.origin !== siteOrigin || url.username || url.password) throw new Error('Use an exact HTTPS SITE_ORIGIN.');
  }
  async function get(path) {
    const response = await fetcher(`https://api.stripe.com/v1${path}`, {
      method: 'GET', headers: { Authorization: `Bearer ${key}`, 'Stripe-Version': '2025-09-30.clover' },
      signal: AbortSignal.timeout(10000),
    });
    if (!response.ok) throw new Error(`Stripe read failed (${response.status}); no setup was changed.`);
    return response.json();
  }
  async function all(path) {
    const rows = [];
    let cursor;
    do {
      const separator = path.includes('?') ? '&' : '?';
      const page = await get(`${path}${separator}limit=100${cursor ? `&starting_after=${encodeURIComponent(cursor)}` : ''}`);
      if (!Array.isArray(page.data)) throw new Error('Stripe returned an invalid list.');
      rows.push(...page.data);
      if (!page.has_more) break;
      const next = page.data.at(-1)?.id;
      if (!next || next === cursor) throw new Error('Stripe pagination did not advance.');
      cursor = next;
    } while (true);
    return rows;
  }
  const [account, prices, hooks] = await Promise.all([
    get('/account'), all('/prices?active=true'), all('/webhook_endpoints'),
  ]);
  return {
    mode: 'test', changesMade: false,
    chargesEnabled: account.charges_enabled === true,
    payoutsEnabled: account.payouts_enabled === true,
    capabilities: account.capabilities || {},
    requiredFieldNames: account.requirements?.currently_due || [],
    managedPaymentsApproval: 'Verify separately in the Dashboard; these booleans do not establish approval.',
    configuredPrices: prices.filter(p => setupPlan.prices.some(e => e.lookup_key === p.lookup_key)).map(p => ({
      lookupKey: p.lookup_key, currency: p.currency, amount: p.unit_amount, type: p.type,
      productIsAloud: p.product === 'aloud' || p.product?.id === 'aloud',
    })),
    webhookConfigured: siteOrigin ? hooks.some(h => {
      try { return h.url === siteOrigin + '/api/webhook' && h.status === 'enabled' && setupPlan.webhook.events.every(e => h.enabled_events?.includes(e) || h.enabled_events?.includes('*')); }
      catch { return false; }
    }) : null,
    webhookOriginRequired: !siteOrigin,
  };
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const action = process.argv[2] || '--plan';
  try {
    if (action === '--plan') console.log(JSON.stringify(setupPlan, null, 2));
    else if (action === '--check') console.log(JSON.stringify(await inspectTestAccount({ key: process.env.STRIPE_SECRET_KEY, siteOrigin: process.env.SITE_ORIGIN }), null, 2));
    else throw new Error('Use --plan (offline) or --check (read-only test account). This script cannot create credentials or activate billing.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
