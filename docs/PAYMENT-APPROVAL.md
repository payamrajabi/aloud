# Aloud sandbox setup: exact approval and secure handoff

Prepared October 9, 2026. This is a reviewable request, not approval or a completed
configuration. PR #1 remains a draft. No secret belongs in this document or chat.

## Smallest next authorization

Approve one sandbox setup on the existing Stripe account **payamrajabi.co**
(`acct_1JMh6PKPgq6zCJEs`) and Vercel **finnandco / aloud**
(`prj_FQf8deM01E0Nx0o9G67DfLJUkqi9`), limited to branch
`codex/fin-874-payment-plumbing` and test-mode purchases. Use an existing Stripe
sandbox/test environment; do not create another financial account.

The secure handoff below lets Payam create and enter access credentials himself.
If the assistant is to create a persistent credential instead, obtain explicit
confirmation for that exact creation at the action, with its permissions visible.
Never reveal credentials to source control, screenshots, logs or messages.

| Proposed action | Persistent scope and limit | Payam's action |
| --- | --- | --- |
| Runtime Stripe credential | Test-only restricted key; Checkout Sessions write/read and Prices read. No product/price/webhook/account/refund/payout writes. Confirm Stripe's required dependency permissions in the Dashboard before saving; do not broaden silently. | Create/reuse the restricted key and enter it into the branch's sensitive `STRIPE_SECRET_KEY` setting. |
| Test product/prices/webhook | Reuse existing matching objects first. Only product `aloud`, the prices in `stripe-setup.mjs --plan`, and the branch test webhook for the two purchase-success events. No live objects. | Approve creation of missing test objects; setup can use the Dashboard so runtime credentials stay restricted. Enter the endpoint secret securely. |
| Test signing issuer | One fresh Ed25519 test pair, private key stored only in branch-scoped sensitive `LICENSE_SIGNING_KEY`; public key may be recorded. Never replace the live app's embedded key. | Approve this exact persistent test-key creation, or supply an existing isolated test issuer securely. |
| Email test delivery | Reuse a Payam-owned Resend account; account identity is still unverified. Sending-only API key, restricted to the approved sender domain where possible. Use `onboarding@resend.dev` and only the account's verified owner address for the smallest test, avoiding DNS changes for email. | Identify the account and approve the single test recipient; create/enter the sending key securely. New account terms or a paid plan require a separate action. |
| Public test origin | Proposed `https://payments-test.aloudformac.com`, assigned only to this preview branch. Only its subdomain DNS record changes; production/root/`www` records stay untouched. | Approve that exact subdomain. Existing Vercel SSO protects Vercel preview hosts and would otherwise block Stripe webhooks. A public test origin avoids creating or putting a protection-bypass secret in a webhook URL. |
| Restore protection | Vercel WAF, only POST `/api/restore` on the approved test host; IP counter, fixed window, 5 allowed requests per 600 seconds, then HTTP 429. Region counters are separate. No database, new SDK, bypass key or storage subscription. | Review and publish the exact rule after its fee is accepted. Keep the restore readiness flag unset until a deployed sixth-request check proves protection. |

Set `ALOUD_PAYMENT_MODE=test`, the exact test `SITE_ORIGIN`, approved email sender,
and `ALOUD_EMAIL_ENABLED=true` only in the branch Preview environment. No setting in
this request targets Production. `ALOUD_ENABLE_LIVE_PAYMENTS` remains absent/false.
The Vercel environment-name read on October 9 returned no project variables and
zero hidden Production variables; no secret values were requested.

The [Vercel Firewall skill](skill://plugin_connector_690a90ec05c881918afb6a55dc9bbaa1/vercel-firewall/SKILL.md)
requires **“Stage drafts; let the user publish.”** Engineering prepares and reviews
the exact rule; Payam publishes it after reviewing scope, traffic and the fee dialog.
The repository's inactive rule is not an operational firewall configuration.

## Fees and account decisions

- Stripe sandbox cards simulate payments; this approval never permits a real charge.
- Resend's Free limits are 100 emails/day and 3,000/month. The account/plan is not yet
  verified; do not upgrade or enter payment details. Test delivery is a real email to
  the one recipient Payam approves.
- Vercel lists WAF rate limiting at **$0.50 per 1,000,000 allowed requests** (region
  pricing may vary). Hobby has 1,000,000 included allowed requests; the connected
  team's billing plan was not exposed by the read. Confirm the actual dashboard
  price/allowance before activation. This document does not approve an uncapped fee.
- Live Managed Payments currently presents a **3.5% add-on fee** on the existing
  Stripe account. It is separate from underlying processing fees. Managed Payments
  activation, terms, identity verification and live sales are outside this sandbox
  request. Payam must perform physical-ID and terms acceptance himself.

## Merge and release effect

Vercel's latest Production deployment is built automatically from GitHub `main`
`910680e`, with `aloudformac.com`/`www` production domains. Merging PR #1 would
automatically deploy the changed homepage and payment routes to that live site.
With no configuration, checkout remains unavailable (503); the new Buy CTA would
therefore lead to an unavailable purchase flow. Keep the draft unmerged until
sandbox acceptance, release-owner coordination and a concrete live rollout are ready.

The independently published Aloud **1.6.2** and its update feed are preserved. This
branch's paid app still needs real signed/notarized release acceptance with the
approved live issuer. Neither an ephemeral fixture nor a locally built executable
certifies the actual live issuer, installed-app activation routing or distribution.

After the sandbox is configured, engineering owns the real test-card checkout,
tax/currency/Managed Payments presentation, success/pending/cancel flow, signed
webhook and email retries, restore protection, isolated app acceptance and final CI.
Payam's remaining decisions are the secure account/key handoff, identified fees and
agreements, physical ID, and final live launch.

Sources checked October 9:
- [Stripe key types and sandbox isolation](https://docs.stripe.com/keys)
- [Resend API-key scopes](https://resend.com/docs/dashboard/api-keys/introduction)
- [Resend free quotas](https://resend.com/docs/knowledge-base/account-quotas-and-limits)
- [Vercel branch domain assignment](https://vercel.com/docs/domains/working-with-domains/assign-domain-to-a-git-branch)
- [Vercel WAF rate limits and pricing](https://vercel.com/docs/vercel-firewall/vercel-waf/rate-limiting)
- [Stripe Managed Payments setup and terms](https://docs.stripe.com/payments/managed-payments/set-up)
