#!/bin/dash
#
# Daily maintenance for a Fjolsky sing-box proxy node.
#
# Every node runs this as root once a day via the update-sbox systemd timer,
# which was installed by the provisioning script and points at a bit.ly link.
# That link used to resolve to a repository outside this organisation, so
# whoever controlled it controlled every node. It now resolves here.
#
# Two jobs:
#   1. Keep sing-box current from the upstream apt repo (what the old script did).
#   2. Re-sync the ACME certificate credential from the API.
#
# Why (2) exists: /v1/server/config is fetched exactly once, by the installer.
# Nodes provisioned before the Cloudflare token was rotated still hold the
# revoked one, so their certificates would fail to renew — around 30 days before
# expiry, silently, with nothing looking wrong until TLS stops working.
#
# Safety: this touches a live proxy. Every failure path leaves the node exactly
# as it was. The config is only replaced after `sing-box check` accepts it, and
# the service is only restarted if the file actually changed.
set +e
export DEBIAN_FRONTEND=noninteractive

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.maint-backup"
SAGER_NET="https://sing-box.app/gpg.key"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

# ── 1. sing-box package update (unchanged behaviour) ──────────────────────────
sudo -E apt-get -qq update
sudo -E apt-get -qq install -o Dpkg::Options::="--force-confold" -y gnupg2 jq

curl -fsSL "$SAGER_NET" | sudo -E gpg --yes --dearmor -o /etc/apt/trusted.gpg.d/sagernet.gpg
echo "deb https://deb.sagernet.org * *" | sudo -E tee /etc/apt/sources.list.d/sagernet.list >/dev/null

sudo -E apt-get -qq update
sudo -E apt-get -qq install -o Dpkg::Options::="--force-confold" -y sing-box

# ── 2. ACME credential re-sync ────────────────────────────────────────────────
# Bail out quietly on anything unexpected: a node with a stale renewal token
# still serves traffic today, so nothing here is worth risking the service for.
[ -f "$CONFIG" ] || { log "no config at $CONFIG, skipping acme sync"; exit 0; }
command -v jq >/dev/null 2>&1 || { log "jq missing, skipping acme sync"; exit 0; }

# The API identifies the node by source IP; no credentials are sent or needed.
DOMAIN=$(jq -r '.inbounds[0].tls.server_name // empty' "$CONFIG" 2>/dev/null \
         | sed 's/^[^.]*\.//')
[ -n "$DOMAIN" ] || DOMAIN="fjolskylduoryggisverndar.com"

RESPONSE=$(curl -fsS --max-time 30 -X POST "https://api.$DOMAIN/v1/server/config" 2>/dev/null)
[ -n "$RESPONSE" ] || { log "config fetch failed, keeping current token"; exit 0; }

WANT=$(printf '%s' "$RESPONSE" | jq -r '.data.config' 2>/dev/null | base64 -d 2>/dev/null \
       | jq -r '.inbounds[0].tls.acme.dns01_challenge.api_token // empty' 2>/dev/null)
[ -n "$WANT" ] || { log "no acme token in response, keeping current"; exit 0; }

HAVE=$(jq -r '.inbounds[0].tls.acme.dns01_challenge.api_token // empty' "$CONFIG" 2>/dev/null)
[ "$WANT" = "$HAVE" ] && { log "acme token already current"; exit 0; }

log "acme token differs, updating"
sudo cp "$CONFIG" "$BACKUP" || exit 0

NEW=$(jq --arg t "$WANT" '.inbounds[0].tls.acme.dns01_challenge.api_token = $t' "$CONFIG")
[ -n "$NEW" ] || { log "jq produced nothing, aborting"; exit 0; }

printf '%s' "$NEW" | sudo tee "$CONFIG.new" >/dev/null
[ -s "$CONFIG.new" ] || { sudo rm -f "$CONFIG.new"; log "empty candidate, aborting"; exit 0; }

sudo mv "$CONFIG.new" "$CONFIG"
if sudo sing-box check -c "$CONFIG" >/dev/null 2>&1; then
    if sudo systemctl restart sing-box; then
        log "acme token updated and sing-box restarted"
    else
        log "restart failed, rolling back"
        sudo cp "$BACKUP" "$CONFIG"
        sudo systemctl restart sing-box
    fi
else
    log "sing-box rejected the new config, rolling back"
    sudo cp "$BACKUP" "$CONFIG"
fi
