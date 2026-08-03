#!/bin/bash
# Redeploy the app-download redirector after a release.
#
# The Worker holds a baked table of release asset URLs, so a new build needs a
# redeploy. Everything else (the dl.<brand> hostnames, the mirror chain) stays
# put. Regenerate the table with build-table.py, then run this.
#
# Needs: CF_TOKEN (Cloudflare API token with Workers Scripts:Edit) and the
# account id below. The token lives in the macOS Keychain on the operator's
# machine:  security find-generic-password -s fjosky.cloudflare.fjolsky -w
set -euo pipefail

ACCOUNT_ID="${CF_ACCOUNT_ID:-72b71eab72f53b1f1e80ea435d40d9e1}"
SCRIPT_NAME="${CF_WORKER_NAME:-fjolsky-downloads}"
SRC="$(dirname "$0")/workers/app-downloads.js"
: "${CF_TOKEN:?set CF_TOKEN first}"

curl -fsS -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -F 'metadata={"main_module":"index.js","compatibility_date":"2026-01-01"};type=application/json' \
  -F "index.js=@${SRC};filename=index.js;type=application/javascript+module" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("deployed" if d.get("success") else d.get("errors"))'

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
