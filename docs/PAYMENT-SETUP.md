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
Every Stripe request pins `2026-04-22.dahlia`, which documents the returned
`managed_payments.enabled` field. Checkout rejects a missing/false returned field
before redirecting. Fulfillment retrieves the canonical Session and its line items
from Stripe rather than accepting the event's metadata as purchase proof. Exactly
one item of quantity one must match an explicitly approved immutable price ID,
the configured Aloud product, payment mode, one-time price and amounts/currency.
Archived approved prices remain eligible for restoration. An older ordinary
Checkout purchase is not treated as a verified Managed Payments purchase.
The approved test endpoint must use the same API version; no account-wide version
upgrade is proposed. Actual provider behavior still needs sandbox acceptance.
[Stripe's Managed Payments API addition](https://docs.stripe.com/changelog/dahlia/2026-04-22/managed-payments)

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
Live HTTP routes also reject an issuer whose public half differs from the fixed paid-app
key; CI verifies that the backend guard and Swift verifier stay synchronized.
No actual account objects, secrets, email settings or production data were changed.

| Setting | Sandbox configuration | Live configuration |
| --- | --- | --- |
| `ALOUD_PAYMENT_MODE` | `test` (default) | `live` |
| `ALOUD_ENABLE_LIVE_PAYMENTS` | absent/false | `true`, only after acceptance |
| `VERCEL_ENV` | supplied by Vercel | must be `production` |
| `STRIPE_SECRET_KEY` | preferred approved `rk_test_…`; `sk_test_…` also accepted | preferred approved `rk_live_…`; `sk_live_…` also accepted |
| `STRIPE_WEBHOOK_SECRET` | test endpoint's `whsec_…` | live endpoint's `whsec_…` |
| `SITE_ORIGIN` | exact HTTPS preview origin, without slash | `https://aloudformac.com` |
| `LICENSE_SIGNING_KEY` | isolated Ed25519 test PEM | approved issuer matching release public key |
| `ALOUD_EMAIL_ENABLED` | explicit `true` after approval | explicit `true` after approval |
| `RESEND_API_KEY` / `LICENSE_EMAIL_FROM` | approved provider/sender and test recipient | verified sender and delivery account |
| `ALOUD_TEST_EMAIL_ALLOWLIST` | explicit comma-separated exact approved addresses; proposed single address `payam.rajabi@gmail.com` | not used; live still needs its separate enablement gates |
| `ALOUD_STRIPE_PRODUCT_ID` | `aloud`, or approved existing product ID | same selected product ID |
| `ALOUD_PRICE_LOOKUP_KEY` | `aloud_launch` | approved launch/regular lookup |
| `ALOUD_APPROVED_PRICE_IDS` | exact actual `price_…` IDs approved after inspecting the test product/prices | separately approved live IDs, retaining historical approved IDs |
| `SUPPORT_EMAIL` | defaults to `payam.rajabi@gmail.com` | confirmed support address |
| `ALOUD_RESTORE_PROTECTION_READY` | absent/false until approved sandbox protection is active and verified | absent/false until separately approved production protection is active and verified |

Configure secrets through approved secure settings, never a PR, log, command argument
or chat. This branch does not authorize new accounts, subscriptions, access credentials,
financial agreements or live enablement. Preserve test/live signing isolation.

Use a separate restricted key for each environment. The runtime calls only
Prices GETs, Checkout Session GETs (including line items), and Checkout Session
POSTs for creation and purchase-email attempt/acceptance metadata, so its
minimum proposed scope is **Checkout Sessions: Write** (includes Read) and
**Prices: Read**, with all other resources None. Products, prices and webhook
endpoints are configured in the Dashboard, so the runtime needs no write permission
for them. It never calls Charges, Refunds, Customers, Payment Intents, subscriptions
or payout APIs directly. Stripe's restricted-key guide maps GET to Read and POST
to Write; any additional Managed Payments permission dependency must be established
in an approved sandbox test and reviewed rather than granting broad access.
No actual restricted key or permissions were created or changed.
[Stripe restricted API keys and permission mapping](https://docs.stripe.com/keys/restricted-api-keys)

The test recipient allowlist is required before checkout is enabled and enforced
again before every purchase/restore email and purchase-email metadata write. There
is no wildcard, implicit support-address fallback, request override, CC or BCC.
Other test buyers can receive a browser license but cannot trigger email to an
unapproved address. The verified connected Gmail mailbox is
`payam.rajabi@gmail.com`; this does not establish Resend account ownership.
Use `Aloud <onboarding@resend.dev>` only after confirming that Resend's associated
account address is that same mailbox and Payam approves delivery. Otherwise obtain
an approved existing verified sender and exact recipient; do not create an account
or change email DNS under this proposal.
[Resend's default-domain recipient restriction](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain)

The optional read-only `--check` inspector also accepts `rk_test_…`. Its separate
inspection credential must allow its GETs to `/v1/account`, Prices and Webhook
Endpoints. Do not broaden the runtime key to run an inspection tool; use the
Dashboard or a separately approved read-only credential. No inspection key belongs
in the deployment. Publishable, organization, malformed and wrong-mode keys remain
rejected by these helpers.

`node scripts/stripe-setup.mjs --plan` prints the price/webhook plan offline.
With an already authorized test key in the environment, `--check` reports sanitized
account readiness and existing prices; with `SITE_ORIGIN`, it checks that exact
webhook URL. It performs GET requests only and never prints keys or webhook secrets.

Register `/api/webhook` for `checkout.session.completed` and
`checkout.session.async_payment_succeeded` in the same mode as checkout. Set the product's
eligible tax code and one-time prices. Use endpoint API version `2026-04-22.dahlia`.
Do not create duplicates if these objects exist. Record the actual approved price IDs
in `ALOUD_APPROVED_PRICE_IDS`; moving a lookup key does not implicitly approve a new ID.

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
   both success event types do not duplicate the purchase email, including a replay
   after 24 hours once Stripe's provider-acceptance marker exists. Verify attempt
   and acceptance metadata writes with the restricted runtime key. An old attempt
   without an acceptance marker must stop for manual reconciliation.
4. Complete the restore protection plan below first: with readiness absent, prove
   deployed request enforcement and restore's pre-provider 503; set readiness only
   after the approved active rule is verified. Then restore the purchase by email
   and confirm no unrelated buyer's license is sent.
   Restore verifies at most 100 eligible purchase candidates, skips ineligible
   ordinary/other-price history, and keeps the public lookup/email result generic.
5. Check app shortcut/pill/player/dictation trial gates and activation UI in an
   isolated test environment. Do not replace the installed app or share its settings.
6. Verify the live issuer's public key matches the release's embedded key, then build,
   sign/notarize and validate the paid release and update feed through the release owner's
   normal process. Confirm legacy free users stay free before enabling sales.
   `node scripts/license-key-check.mjs` checks an already approved issuer supplied
   through `LICENSE_SIGNING_KEY`; it creates no key and prints only match/mismatch.

Identity verification, Managed Payments terms/approval, secure configuration approvals
and final live enablement belong to Payam. Engineering completes the sandbox and release
acceptance after those settings are available; Payam need not debug the implementation.

## Restore protection plan (unactivated)

[`../ops/restore-waf-rule.preview.json`](../ops/restore-waf-rule.preview.json) is an
inactive proposal in the official Vercel CLI rule JSON shape. It is not loaded by
`vercel.json`, has not been staged or published, and provides no active rate limiting.
Its conditions are ANDed: host equals `payments-test.aloudformac.com`, path equals
`/api/restore`, and method equals `POST`. Its proposed action returns 429 after
five requests from an IP in a 600-second fixed window. Checkout, license reads,
webhooks and other hostnames are outside this rule. A production rule requires
separate approval; copying this sandbox rule does not protect production.

Vercel tracks counters per region, so the same IP reaching multiple regions can
exceed five requests globally. Fixed windows can also allow bursts across their
boundary, and people sharing an IP share a quota. This is an initial IP abuse limit,
not a global or per-email guarantee. The endpoint still verifies returned purchase
email and hides whether a purchase exists. Its hourly email idempotency buckets are
not a substitute for request throttling.

Vercel publishes a base rate of **$0.50 per million allowed requests**; regional
rates can be higher. The team's plan, included usage, existing rules, spend controls
and billing terms are unverified. Payam must approve any pricing dialog/fees and the
exact sandbox scope before operational changes. No fee, SDK, new storage provider,
firewall rule or credential is authorized or installed by this artifact.

After approval, engineering reviews existing rules and bypasses, stages/logs the
narrow sandbox rule, inspects its draft, and has the owner publish the reviewed
configuration. Review traffic before enabling enforcement. The saved JSON's
`active:false` must be deliberately changed for approved enforcement; publishing
it unchanged does not establish protection. Keep readiness absent/false while
proving that the active rule is enforced on the exact hostname/path/method. With
readiness still closed, allowed restore requests return 503 and make no provider
calls; the sixth request in the same regional window should return platform 429.
Confirm logs, bypass ordering, hostname routing, allowed methods and normal form
retry behavior. Do not use this test to open credentials or provider access.

Only after approval and verified active enforcement set
`ALOUD_RESTORE_PROTECTION_READY=true` in the corresponding approved deployment
configuration. **This flag is an operator self-attestation, not runtime proof of
an active rule.** Setting it alone removes the provider-call gate without limiting
requests; headers, form fields and query parameters cannot set it. Never inherit a
sandbox readiness setting into production. Before removing or changing protection,
unset the flag, deploy, and verify restore returns 503 before provider calls again.

The UI handles platform 429 responses even when their body is HTML, honors a valid
`Retry-After` value (or waits ten minutes if unavailable), and preserves the email
for manual retry. It never automatically resends a restore request. The local
`payment-preview.mjs` simulation remains provider-disabled and needs no readiness
configuration; its 503 now displays a useful message instead of a JSON parse error.

Official schema/behavior references checked October 9, 2026:
- [Vercel CLI action builder](https://github.com/vercel/vercel/blob/main/packages/cli/src/util/firewall/build-action.ts)
- [Vercel CLI firewall rule types](https://github.com/vercel/vercel/blob/main/packages/cli/src/util/firewall/types.ts)
- [WAF rate limiting and regional counters](https://vercel.com/docs/vercel-firewall/vercel-waf/rate-limiting)
- [WAF usage and pricing](https://vercel.com/docs/vercel-firewall/vercel-waf/usage-and-pricing)
- [Regional pricing](https://vercel.com/docs/pricing/regional-pricing)
- [Vercel CLI staging and publishing](https://vercel.com/docs/cli/firewall)

## Delivery limits

Resend's session-scoped purchase idempotency lasts 24 hours. The webhook also writes
`aloud_email_attempt_at` (Unix seconds) to the canonical Stripe Session before the
first send, then `aloud_email_accepted=v1` after Resend accepts it. These two metadata
writes are the only proposed additional persistent runtime mutations. An acceptance
marker suppresses later automatic sends indefinitely; it establishes provider
acceptance, not inbox delivery. Invalid markers, or an unacknowledged attempt at least
23 hours old, return 503 for manual reconciliation. This deliberately stops even
when the first attempt may never have reached Resend. It does not promise exactly-once
delivery across an ambiguous provider failure. The operator must inspect the specific
Session and Resend record before any explicitly approved retry or marker repair.
Stripe can cache an executed POST failure under its idempotency key; a cached
marker-write failure can therefore stay blocked and need operator repair rather
than recover automatically on a retry. Do not remove/change a key to force a send.

Keep sender/origin/template/signing settings stable while retries are pending to
avoid idempotency payload conflicts. Failures inside the retry window return a
retryable webhook response. Restore keys use hourly buckets, so cross-boundary
manual restore requests can send again. Restore intentionally hides lookup/email
outcomes from the requester. These limits are separate from request throttling.

Refund eligibility is unresolved: a paid Checkout Session does not prove that the
charge is unrefunded, and current restoration can reissue after a refund. No refund
read permission or new refund event subscription is included. Payam must choose the
refund/reissue policy before launch; engineering then implements the approved control.
Already issued offline licenses cannot be remotely revoked.
[Resend idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys)
