#!/bin/bash
# Deploy the referral short-link Worker (fjolsky-referral) and bind the pool
# domains. See app-referral.md for what it serves and how rotation works.
#
# Bindings: the R2 bucket `fjolsky-downloads` as DOWNLOADS (same bucket and
# layout fjolsky-downloads streams from -- nothing is duplicated) and the
# Analytics Engine dataset below as REFERRAL_CLICKS. Set WITH_ANALYTICS=0 to
# deploy without the dataset binding (e.g. a token that cannot create it).
#
# Needs: CF_TOKEN (Cloudflare API token with Workers Scripts:Edit) and the
# account id below. The token lives in the macOS Keychain on the operator's
# machine:  security find-generic-password -s fjosky.cloudflare.fjolsky -w
#
# Pool domains must be ACTIVE zones in this account before binding (a pending
# zone makes the domains/records call fail for that hostname only; re-run
# later). Binding is idempotent.
set -euo pipefail

ACCOUNT_ID="${CF_ACCOUNT_ID:-72b71eab72f53b1f1e80ea435d40d9e1}"
SCRIPT_NAME="${CF_WORKER_NAME:-fjolsky-referral}"
R2_BUCKET="${R2_BUCKET:-fjolsky-downloads}"
DATASET="${CF_AE_DATASET:-fjolsky_referral_clicks}"
WITH_ANALYTICS="${WITH_ANALYTICS:-1}"
SRC="$(dirname "$0")/workers/app-referral.js"
: "${CF_TOKEN:?set CF_TOKEN first}"

# Keep in sync with TABLE in workers/app-referral.js. Rotation order is NOT
# here -- it lives in hydra (RuleConfig.referral_short_domains).
POOL_DOMAINS="${POOL_DOMAINS:-109238784623.shop 238423904823.shop 542758625546.shop 109238784623.xyz 238423904823.xyz 542758625546.xyz}"

BINDINGS="{\"type\":\"r2_bucket\",\"name\":\"DOWNLOADS\",\"bucket_name\":\"${R2_BUCKET}\"}"
if [ "${WITH_ANALYTICS}" = "1" ]; then
  BINDINGS="${BINDINGS},{\"type\":\"analytics_engine\",\"name\":\"REFERRAL_CLICKS\",\"dataset\":\"${DATASET}\"}"
fi

curl -fsS -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -F "metadata={\"main_module\":\"index.js\",\"compatibility_date\":\"2026-08-04\",\"bindings\":[${BINDINGS}]};type=application/json" \
  -F "index.js=@${SRC};filename=index.js;type=application/javascript+module" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("deployed" if d.get("success") else d.get("errors"))'

# Apex hostnames straight onto the Worker (Cloudflare "custom domains": the DNS
# record and certificate are managed for us; nothing else may live on the apex).
for d in ${POOL_DOMAINS}; do
  if curl -fsS -X PUT \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/domains/records" \
      -H "Authorization: Bearer ${CF_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"environment\":\"production\",\"hostname\":\"${d}\",\"service\":\"${SCRIPT_NAME}\",\"zone_name\":\"${d}\"}" \
      >/dev/null; then
    echo "bound ${d}"
  else
    echo "NOT bound ${d} (zone not active yet?)"
  fi
done

# Smoke test: root must 404, a code must render, each platform must answer
# with the R2 headers (x-fjolsky-source: r2) -- a 302 means the bucket has no
# manifest and the request fell back to dl.<brand>.
for d in ${POOL_DOMAINS}; do
  printf "%-20s /            " "$d"; curl -s -o /dev/null -m 15 -w "%{http_code}\n" "https://${d}/"
  printf "%-20s /ABC123      " "$d"; curl -s -o /dev/null -m 15 -w "%{http_code} %{content_type}\n" "https://${d}/ABC123"
  for p in android windows macos; do
    printf "%-20s /ABC123/%-7s" "$d" "$p"
    curl -sI -m 15 "https://${d}/ABC123/${p}" | awk 'BEGIN{c="";s="-";l="-"} /^HTTP/{c=$2} tolower($1)=="x-fjolsky-source:"{s=$2} tolower($1)=="content-length:"{l=$2} END{printf "%s src=%s len=%s\n", c, s, l}'
  done
done
