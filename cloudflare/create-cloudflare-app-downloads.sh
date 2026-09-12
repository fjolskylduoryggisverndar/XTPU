#!/bin/bash
# Redeploy the app-download redirector after a release.
#
# The Worker holds a baked table of release asset URLs, so a new build needs a
# redeploy. Everything else (the dl.<brand> hostnames, the mirror chain) stays
# put. Regenerate the table with build-table.py, then run this.
#
# [2026-09-07] The paragraph above is historical: since 2026-08-04 the Worker
# resolves the latest tag at request time, and since 2026-09-07 it serves the
# bytes from the R2 bucket `fjolsky-downloads` (falling back to GitHub when a
# brand/platform has no manifest there). A redeploy is only needed when the
# Worker source itself changes. The R2 bucket is bound as `DOWNLOADS` below;
# the bucket must already exist (create once with the R2-scoped token:
#   curl -X POST https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/r2/buckets \
#        -H "Authorization: Bearer $CF_R2_TOKEN" -d '{"name":"fjolsky-downloads","locationHint":"apac"}').
#
# Needs: CF_TOKEN (Cloudflare API token with Workers Scripts:Edit) and the
# account id below. The token lives in the macOS Keychain on the operator's
# machine:  security find-generic-password -s fjosky.cloudflare.fjolsky -w
set -euo pipefail

ACCOUNT_ID="${CF_ACCOUNT_ID:-72b71eab72f53b1f1e80ea435d40d9e1}"
SCRIPT_NAME="${CF_WORKER_NAME:-fjolsky-downloads}"
R2_BUCKET="${R2_BUCKET:-fjolsky-downloads}"
SRC="$(dirname "$0")/workers/app-downloads.js"
: "${CF_TOKEN:?set CF_TOKEN first}"

# [2026-09-07] previous deploy call, kept for reference -- it uploaded the script
# with no bindings, so the Worker could only ever redirect to GitHub:
# curl -fsS -X PUT \
#   "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}" \
#   -H "Authorization: Bearer ${CF_TOKEN}" \
#   -F 'metadata={"main_module":"index.js","compatibility_date":"2026-01-01"};type=application/json' \
#   -F "index.js=@${SRC};filename=index.js;type=application/javascript+module" \
#   | python3 -c 'import sys,json; d=json.load(sys.stdin); print("deployed" if d.get("success") else d.get("errors"))'
# [2026-09-12 referral-ref] The Worker now also writes one Analytics Engine row per
# download that carries ?ref=<CODE> (same dataset and blob schema as fjolsky-referral,
# see app-referral.md). The account has Analytics Engine enabled since 2026-09-12;
# WITH_ANALYTICS=0 deploys without that binding (downloads work, counts are skipped).
# was (R2 binding only):
#   -F "metadata={\"main_module\":\"index.js\",\"compatibility_date\":\"2026-08-04\",\"bindings\":[{\"type\":\"r2_bucket\",\"name\":\"DOWNLOADS\",\"bucket_name\":\"${R2_BUCKET}\"}]};type=application/json" \
DATASET="${CF_AE_DATASET:-fjolsky_referral_clicks}"
WITH_ANALYTICS="${WITH_ANALYTICS:-1}"
BINDINGS="{\"type\":\"r2_bucket\",\"name\":\"DOWNLOADS\",\"bucket_name\":\"${R2_BUCKET}\"}"
if [ "${WITH_ANALYTICS}" = "1" ]; then
  BINDINGS="${BINDINGS},{\"type\":\"analytics_engine\",\"name\":\"REFERRAL_CLICKS\",\"dataset\":\"${DATASET}\"}"
fi
curl -fsS -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -F "metadata={\"main_module\":\"index.js\",\"compatibility_date\":\"2026-08-04\",\"bindings\":[${BINDINGS}]};type=application/json" \
  -F "index.js=@${SRC};filename=index.js;type=application/javascript+module" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("deployed" if d.get("success") else d.get("errors")); sys.exit(0 if d.get("success") else 1)'

# The dl.<brand> hostnames only need binding once; re-binding is harmless.
for d in buddhajump.xyz kamevpn.xyz aiglefree.xyz goddessv.xyz libertygatevpn.xyz \
         maschvpn.xyz maskaura.xyz ninjashield.xyz openbridgeapp.xyz \
         00000vpn.com 88888vpn.com; do
  curl -fsS -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/domains/records" \
    -H "Authorization: Bearer ${CF_TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"environment\":\"production\",\"hostname\":\"dl.${d}\",\"service\":\"${SCRIPT_NAME}\",\"zone_name\":\"${d}\"}" \
    >/dev/null && echo "bound dl.${d}"
done

# [2026-09-07] Smoke test: every brand/platform should answer with the R2 headers
# (x-fjolsky-source: r2) or, where the bucket has nothing yet, a 302 to GitHub.
for d in buddhajump.xyz kamevpn.xyz aiglefree.xyz goddessv.xyz libertygatevpn.xyz \
         maschvpn.xyz maskaura.xyz ninjashield.xyz openbridgeapp.xyz \
         00000vpn.com 88888vpn.com; do
  for p in android windows macos; do
    printf "%-22s %-8s " "$d" "$p"
    curl -sI -m 15 "https://dl.${d}/${p}" | awk 'BEGIN{c="";s="-";l="-"} /^HTTP/{c=$2} tolower($1)=="x-fjolsky-source:"{s=$2} tolower($1)=="content-length:"{l=$2} END{printf "%s src=%s len=%s\n", c, s, l}'
  done
done

# [2026-09-12 referral-ref] A HEAD with ?ref=<CODE> must echo the code (x-fjolsky-ref) and
# serve the identical object (same ETag as the plain URL). HEAD writes no analytics row.
for d in buddhajump.xyz kamevpn.xyz; do
  printf "%-22s ref-echo " "$d"
  curl -sI -m 15 "https://dl.${d}/android?ref=TEST01" | awk 'BEGIN{r="-";e="-"} tolower($1)=="x-fjolsky-ref:"{r=$2} tolower($1)=="etag:"{e=$2} END{printf "ref=%s etag=%s\n", r, e}'
done
