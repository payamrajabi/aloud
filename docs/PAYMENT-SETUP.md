# Aloud payment setup and launch acceptance

FIN-874 selects Stripe **Managed Payments**, a one-time $9.99 USD/CAD launch
price, $19 USD/CAD regular price, a seven-day full trial, and free access for
existing free users. Regular local amounts are EUR 19, GBP 17 and AUD 29.
No foreign launch amounts are invented. The launch lookup key is `aloud_launch`;
changing it to `aloud_regular` does not require an app release.

## Merchant-of-record requirement

`api/buy.mjs` sends `managed_payments[enabled]=true` with `mode=payment`.
It does not implement a standard-Checkout fallback or infer merchant-of-record
coverage from `automatic_tax`. Stripe failures keep checkout unavailable.

On October 9, the existing account's Managed Payments settings showed **Get started**
and a 3.5% add-on fee. Activation and terms acceptance were not performed. The
account also showed payouts paused, and the owner reported needing physical ID.
Those are separate requirements; completing ID alone does not establish Managed
Payments approval. Canada is a supported business location, but Stripe still
reviews business eligibility. The product must have an eligible software tax code.
The offline plan uses `txcd_10202000`; confirm its classification in the Dashboard.

Stripe handles indirect tax compliance in its supported countries, not all countries
worldwide. Before live sales, confirm the intended markets are covered; retain the
managed model if any account/product requirement fails.

Sources checked October 9, 2026:
- [Managed Payments setup and required terms](https://docs.stripe.com/payments/managed-payments/set-up)
- [Business and product eligibility](https://docs.stripe.com/payments/managed-payments/eligibility)
- [Tax coverage](https://docs.stripe.com/payments/managed-payments/tax-compliance)

## Prepared code; configuration still required

All API routes default to test mode. A preview cannot run live payments even if it
inherits a live key. Checkout checks fulfillment configuration before contacting Stripe.
No actual account objects, secrets, email settings or production data were changed.

| Setting | Sandbox configuration | Live configuration |
| --- | --- | --- |
| `ALOUD_PAYMENT_MODE` | `test` (default) | `live` |
| `ALOUD_ENABLE_LIVE_PAYMENTS` | absent/false | `true`, only after acceptance |
| `VERCEL_ENV` | supplied by Vercel | must be `production` |
| `STRIPE_SECRET_KEY` | approved `sk_test_…` | approved `sk_live_…` |
| `STRIPE_WEBHOOK_SECRET` | test endpoint's `whsec_…` | live endpoint's `whsec_…` |
| `SITE_ORIGIN` | exact HTTPS preview origin, without slash | `https://aloudformac.com` |
| `LICENSE_SIGNING_KEY` | isolated Ed25519 test PEM | approved issuer matching release public key |
| `ALOUD_EMAIL_ENABLED` | explicit `true` after approval | explicit `true` after approval |
| `RESEND_API_KEY` / `LICENSE_EMAIL_FROM` | approved provider/sender and test recipient | verified sender and delivery account |
| `ALOUD_STRIPE_PRODUCT_ID` | `aloud`, or approved existing product ID | same selected product ID |
| `ALOUD_PRICE_LOOKUP_KEY` | `aloud_launch` | approved launch/regular lookup |
| `SUPPORT_EMAIL` | defaults to `payam.rajabi@gmail.com` | confirmed support address |

Configure secrets through approved secure settings, never a PR, log, command argument
or chat. This branch does not authorize new accounts, subscriptions, access credentials,
financial agreements or live enablement. Preserve test/live signing isolation.

`node scripts/stripe-setup.mjs --plan` prints the price/webhook plan offline.
With an already authorized test key in the environment, `--check` reports sanitized
account readiness and existing prices; with `SITE_ORIGIN`, it checks that exact
webhook URL. It performs GET requests only and never prints keys or webhook secrets.

Register `/api/webhook` for `checkout.session.completed` and
`checkout.session.async_payment_succeeded` in the same mode as checkout. Set the product's
eligible tax code and one-time prices. Do not create duplicates if these objects exist.

## Verification before live enablement

The automated tests use mocked provider fetches and ephemeral in-memory signing keys.
They verify named Vercel GET/POST handlers, signature and mode boundaries, fulfillment
retries, restoration pagination, browser activation behavior, trial policy and actual
JavaScript-to-Swift CryptoKit signature interoperability. They do **not** exercise Stripe,
Resend, a deployed Vercel runtime or the installed application's UI.

```sh
node --test Tests/payments/regression.test.mjs Tests/setup/*.test.mjs
bash Tests/licensing/run.sh
node scripts/stripe-setup.mjs --plan
```

`node scripts/payment-preview.mjs` serves a local UI simulation at
`http://127.0.0.1:8784/thanks?session_id=cs_test_preview`. It calls no provider and
cannot create a production license. Test success pages never open the installed app.
The production app accepts only live-mode licenses; sandbox licenses must remain
rejected. Use the pure verifier harness for sandbox signature acceptance.

After approved sandbox configuration:
1. Build/smoke-test the Vercel preview routes. Missing configuration must remain 503.
2. Complete a real Stripe test-card purchase through the managed checkout. Confirm
   the sold-through-Link presentation, configured price, currency and tax treatment,
   and tax withheld in Stripe's transaction details.
3. Confirm paid success yields a test license, pending/cancelled/unpaid flows do not,
   signed webhook delivery reaches only the approved test recipient, and retries of
   both success event types do not duplicate the purchase email within 24 hours.
4. Restore that purchase by email and confirm no unrelated buyer's license is sent.
5. Check app shortcut/pill/player/dictation trial gates and activation UI in an
   isolated test environment. Do not replace the installed app or share its settings.
6. Verify the live issuer's public key matches the release's embedded key, then build,
   sign/notarize and validate the paid release and update feed through the release owner's
   normal process. Confirm legacy free users stay free before enabling sales.
   `node scripts/license-key-check.mjs` checks an already approved issuer supplied
   through `LICENSE_SIGNING_KEY`; it creates no key and prints only match/mismatch.
7. Apply and verify an approved request-rate limit on `/api/restore` before public
   live launch. No new paid storage service is required or configured by this branch.

Identity verification, Managed Payments terms/approval, secure configuration approvals
and final live enablement belong to Payam. Engineering completes the sandbox and release
acceptance after those settings are available; Payam need not debug the implementation.

## Delivery limits

Resend purchase idempotency is scoped to the checkout session and deduplicates for
24 hours. It is not durable beyond that window. Restore keys use hourly buckets, so
cross-boundary retries can send again. Keep sender/origin/template/signing settings
stable while retries are pending to avoid provider payload conflicts. Failed delivery
returns a retryable webhook response. Restore intentionally hides lookup/delivery outcomes
from the requester. Offline licenses cannot be remotely revoked after refunds.
[Resend idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys)
