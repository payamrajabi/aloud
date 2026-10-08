#!/bin/zsh
# One-time Stripe setup for selling Aloud. Safe to re-run: anything that exists is left alone.
#   STRIPE_SECRET_KEY=sk_test_… ./scripts/stripe-setup.sh   (sandbox first, then again with sk_live_…)
# Creates:
#   - the product "Aloud" (tax code: downloadable software, so Managed Payments accepts it)
#   - two one-time prices, found by lookup key:
#       aloud_launch   $9.99 · C$9.99 · €9.99 · £8.99 · A$14.99
#       aloud_regular  $19   · C$19   · €19   · £17   · A$29
#     US and Canadian prices have tax added at checkout; euro, pound and Australian prices include it.
#   - the webhook that emails licenses (prints its signing secret for Vercel's STRIPE_WEBHOOK_SECRET)
# /buy sells whichever price ALOUD_PRICE_LOOKUP_KEY names on Vercel, so switching from the
# launch price to the regular one is a settings change, not a release.
set -euo pipefail
: "${STRIPE_SECRET_KEY:?Set STRIPE_SECRET_KEY to your Stripe secret key}"
SITE="${SITE:-https://aloudformac.com}"

api() {  # api METHOD PATH [curl -d args…]
  local method=$1 path=$2; shift 2
  curl -sSg -X "$method" "https://api.stripe.com/v1$path" -u "$STRIPE_SECRET_KEY:" \
    -H "Stripe-Version: 2025-09-30.clover" "$@"
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {'d': d}))" "$1"; }

if [[ $(api GET /products/aloud | field "'error' in d") == True ]]; then
  api POST /products -d id=aloud -d name=Aloud \
    --data-urlencode "description=Reads to you, listens to you. One-time purchase for all your Macs." \
    -d tax_code=txcd_10202000 -d "url=$SITE" >/dev/null
  echo "Created product: aloud"
else
  echo "Product aloud: already there"
fi

price() {  # price LOOKUP_KEY USD CAD EUR GBP AUD (in cents)
  local key=$1
  if [[ $(api GET "/prices?lookup_keys[]=$key&active=true" | field "len(d['data'])") != 0 ]]; then
    echo "Price $key: already there"; return
  fi
  api POST /prices -d product=aloud -d lookup_key="$key" \
    -d unit_amount="$2" -d currency=usd -d tax_behavior=exclusive \
    -d "currency_options[cad][unit_amount]=$3" -d "currency_options[cad][tax_behavior]=exclusive" \
    -d "currency_options[eur][unit_amount]=$4" -d "currency_options[eur][tax_behavior]=inclusive" \
    -d "currency_options[gbp][unit_amount]=$5" -d "currency_options[gbp][tax_behavior]=inclusive" \
    -d "currency_options[aud][unit_amount]=$6" -d "currency_options[aud][tax_behavior]=inclusive" \
    | field "d.get('id') or d['error']['message']"
}
price aloud_launch 999 999 999 899 1499
price aloud_regular 1900 1900 1900 1700 2900

HOOK="$SITE/api/webhook"
if [[ $(api GET "/webhook_endpoints?limit=100" | field "any(e['url'] == '$HOOK' for e in d['data'])") == True ]]; then
  echo "Webhook $HOOK: already there (its secret is in the Stripe Dashboard → Workbench → Webhooks)"
else
  echo "Created webhook $HOOK. Put this in Vercel as STRIPE_WEBHOOK_SECRET:"
  api POST /webhook_endpoints -d "url=$HOOK" \
    -d "enabled_events[]=checkout.session.completed" -d "enabled_events[]=checkout.session.async_payment_succeeded" \
    | field "d.get('secret') or d['error']['message']"
fi
