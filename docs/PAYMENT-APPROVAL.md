# Aloud sandbox setup: exact approval and secure handoff

Prepared October 9, 2026. This is a reviewable request, not approval or a completed
configuration. PR #1 remains a draft. No secret belongs in this document or chat.

## Smallest next authorization

Approve one sandbox setup on the existing Stripe account **payamrajabi.co**
(`acct_1JMh6PKPgq6zCJEs`) and Vercel **finnandco / aloud**
(team `team_rlfKnKMORJ4XhyezCLoTEWom`, project
`prj_FQf8deM01E0Nx0o9G67DfLJUkqi9`), limited to branch
`codex/fin-874-payment-plumbing` and test-mode purchases. Use an existing Stripe
sandbox/test environment; do not create another financial account.

The secure handoff below lets Payam create and enter access credentials himself.
If the assistant is to create a persistent credential instead, obtain explicit
confirmation for that exact creation at the action, with its permissions visible.
Never reveal credentials to source control, screenshots, logs or messages.

| Proposed action | Persistent scope and limit | Payam's action |
| --- | --- | --- |
| Runtime Stripe credential | Test-only `rk_test_…`, proposed name `aloud-fin874-preview-runtime`; Checkout Sessions Write (includes Read) and Prices Read, other resources None. Session writes create checkout and persist only `aloud_email_attempt_at` / `aloud_email_accepted` email markers. No product/price/webhook/account/refund/payout writes. Confirm any Managed Payments dependency in the Dashboard before saving; do not broaden silently. | Create/reuse the restricted key and enter it into branch-sensitive `STRIPE_SECRET_KEY`. This proposal does not authorize the assistant to create it. |
| Test product/prices/webhook | Reuse matching objects first. Product `aloud` with software tax code `txcd_10202000`; one-time launch USD/CAD 9.99, regular USD/CAD/EUR 19, GBP 17, AUD 29. Exact actual approved price IDs go in `ALOUD_APPROVED_PRICE_IDS`; no invented IDs. Branch test `/api/webhook`, only `checkout.session.completed` and `checkout.session.async_payment_succeeded`, endpoint API version `2026-04-22.dahlia`. No account-wide API upgrade or live objects. | Approve creating missing test objects; use the Dashboard so runtime credentials stay restricted. Review/record actual product and price IDs, then enter the endpoint secret securely. |
| Test signing issuer | One fresh Ed25519 test pair, private key stored only in branch-scoped sensitive `LICENSE_SIGNING_KEY`; public key may be recorded. Never replace the live app's embedded key. | Approve this exact persistent test-key creation, or supply an existing isolated test issuer securely. |
| Email test delivery | Proposed exact recipient **`payam.rajabi@gmail.com`**, verified by connected Gmail profile on October 9; at most 10 real test license emails during acceptance. Resend account/team, associated owner address, plan and sender eligibility remain unverified. Proposed sender **`Aloud <onboarding@resend.dev>`** is usable only if that Resend account's associated address is the same mailbox. Sending-only API key; restrict to the approved sender domain if offered. Enforce `ALOUD_TEST_EMAIL_ALLOWLIST=payam.rajabi@gmail.com`; no other recipient, CC/BCC or wildcard. | Verify the existing Resend account and sender first, then approve this exact delivery scope and create/enter the sending key securely. Engineering tracks the 10-email operational cap; the code enforces recipient scope. A different account-associated address or verified sender needs its own exact review. No new account, paid plan or email DNS change is included. |
| Public test origin | Proposed `https://payments-test.aloudformac.com`, assigned only to this preview branch. Only its subdomain DNS record changes; production/root/`www` records stay untouched. | Approve that exact subdomain. Existing Vercel SSO protects Vercel preview hosts and would otherwise block Stripe webhooks. A public test origin avoids creating or putting a protection-bypass secret in a webhook URL. |
| Restore protection | Vercel WAF, only POST `/api/restore` on the approved test host; IP counter, fixed window, 5 allowed requests per 600 seconds, then HTTP 429. Region counters are separate. Proposed incremental paid spend **$0**: proceed only within verified existing included usage; if a fee, payment dialog or uncapped overage applies, stop for an exact revised quote/cap. No database, new SDK, bypass key or storage subscription. | Review and publish the exact rule only after the actual plan, inclusion and fee are verified. Keep restore readiness unset until a deployed sixth-request check proves protection. |

Set `ALOUD_PAYMENT_MODE=test`, the exact test `SITE_ORIGIN`, approved email sender,
`ALOUD_TEST_EMAIL_ALLOWLIST=payam.rajabi@gmail.com`, actual approved price IDs and
`ALOUD_EMAIL_ENABLED=true` only in the branch Preview environment after approval.
Default lookup is `aloud_launch`; use the approved actual product ID. No setting in
this request targets Production. `ALOUD_ENABLE_LIVE_PAYMENTS` remains absent/false.
The Vercel environment-name read on October 9 returned no project variables and
zero hidden Production variables; no secret values were requested.

The [Vercel Firewall skill](skill://plugin_connector_690a90ec05c881918afb6a55dc9bbaa1/vercel-firewall/SKILL.md)
requires **“Stage drafts; let the user publish.”** Engineering prepares and reviews
the exact rule; Payam publishes it after reviewing scope, traffic and the fee dialog.
The repository's inactive rule is not an operational firewall configuration.

## Fees and account decisions

- The connected Gmail profile verifies Payam's exact mailbox, not Resend ownership.
  A verified Resend account/team and associated owner address are missing evidence;
  this bundle cannot truthfully label the proposed sender as ready. No email is sent
  until that check and the exact delivery approval are complete.
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

## Email replay and refund decisions

The runtime's approved Session Write permission would also persist two email-only
metadata fields: `aloud_email_attempt_at` before the first send and
`aloud_email_accepted=v1` after Resend accepts it. Acceptance suppresses automatic
purchase replays indefinitely, including after Resend's 24-hour idempotency expiry.
An unacknowledged attempt at least 23 hours old stops for manual reconciliation;
neither editing a marker nor sending again is automatically authorized. Acceptance
does not prove inbox delivery or exactly-once delivery after an ambiguous failure.
Keep issuer, sender, origin and template stable while a retry is pending.
An executed Stripe marker-write failure can remain cached under its idempotency
key and need operator reconciliation; retries do not guarantee automatic recovery.

Payam must choose the refund/reissue policy before launch. Current restoration
can reissue for a refunded purchase because a paid Session does not prove the
charge is unrefunded. No refund endpoint permission or event subscription is
included in this request. Existing offline licenses cannot be remotely revoked.
This decision does not block mock tests or preparation of the test configuration.

## Merge and release effect

Vercel's latest Production deployment is built automatically from GitHub `main`
`17475b2` (the existing narration work, integrated into this draft), with
`aloudformac.com`/`www` production domains. Merging PR #1 would
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
- [Resend default-domain recipient restriction](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain)
- [Resend 24-hour idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys)
- [Stripe Managed Payments API version](https://docs.stripe.com/changelog/dahlia/2026-04-22/managed-payments)
- [Resend free quotas](https://resend.com/docs/knowledge-base/account-quotas-and-limits)
- [Vercel branch domain assignment](https://vercel.com/docs/domains/working-with-domains/assign-domain-to-a-git-branch)
- [Vercel WAF rate limits and pricing](https://vercel.com/docs/vercel-firewall/vercel-waf/rate-limiting)
- [Stripe Managed Payments setup and terms](https://docs.stripe.com/payments/managed-payments/set-up)
