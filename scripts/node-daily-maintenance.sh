#!/bin/dash
#
# Daily maintenance for a Fjolsky sing-box proxy node.
#
# Every node runs this as root once a day via the update-sbox systemd timer,
# which was installed by the provisioning script and points at a bit.ly link.
# That link used to resolve to a repository outside this organisation, so
# whoever controlled it controlled every node. It now resolves here.
#
# Three jobs:
#   1. Keep sing-box current from the upstream apt repo (what the old script did).
#   2. Apply per-client-IP fair-share shaping (anti-abuse). [added v2 2026-08]
#   3. Re-sync the ACME certificate credential from the API.
#
# Why (3) exists: /v1/server/config is fetched exactly once, by the installer.
# Nodes provisioned before the Cloudflare token was rotated still hold the
# revoked one, so their certificates would fail to renew — around 30 days before
# expiry, silently, with nothing looking wrong until TLS stops working.
#
# Safety: this touches a live proxy. Every failure path leaves the node exactly
# as it was. The config is only replaced after `sing-box check` accepts it, and
# the service is only restarted if the file actually changed. The shaping step
# (2) rebuilds a tc tree fresh each run and tears it back down (node returns to
# its prior un-shaped state) if the node fails a post-apply health check.
set +e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/sbin:/usr/bin:/bin:$PATH

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

# ── 2. Per-client-IP fair-share shaping (anti-abuse) ──────────────────────────
# [added v2 2026-08] Rolls the per-IP rate limit to the whole fleet via the
# self-heal timer instead of SSHing 40+ nodes. Idempotent (rebuilt each run) and
# fail-open by construction:
#   * a node that runs the daily-volume TIERED throttle (HK) is skipped — its own
#     systemd unit owns shaping and a flat tree here would clobber it;
#   * nodes on the explicit special-management IP list are skipped;
#   * if anything is missing (no tc, no uplink) the step returns without touching
#     the node;
#   * after apply, a health gate (sing-box active + egress reachable + full tree)
#     must pass, else the whole tree is torn down and the node is left un-shaped
#     exactly as before.
# Shaping only touches the client plane (tcp sport/dport 443). The node's own
# egress (WARP udp/2408, DNS/53, SSH/22, ACME dns01 which is outbound dport 443
# with an ephemeral sport) never matches the sport/dport-443 hash and rides the
# unshaped default class.
SPECIAL_IPS="191.222.218.103"     # HK001: managed by node-tierlimit (tiered)

apply_shaping() {
    command -v tc >/dev/null 2>&1 || { log "shaping: tc absent, skip"; return 0; }

    # Skip tiered nodes (HK): presence of the tier apply script or the nft ledger.
    if [ -x /usr/local/sbin/node-tierlimit-apply.sh ] \
       || nft list table ip fjolsky_tiers >/dev/null 2>&1; then
        log "shaping: tiered node, leaving shaping to node-tierlimit"; return 0
    fi

    # Skip explicit special-management IPs (belt-and-suspenders for HK).
    MYIP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null)
    for sip in $SPECIAL_IPS; do
        [ "$MYIP" = "$sip" ] && { log "shaping: special IP $MYIP, skip"; return 0; }
    done

    DEV=$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    [ -n "$DEV" ] || { log "shaping: no uplink dev, skip"; return 0; }
    [ "$DEV" = lo ] && { log "shaping: refuse lo, skip"; return 0; }

    # [2026-09-01] Ceilings raised 3x on operator instruction: the old 12mbit
    # per-client ceiling was shaping real playback, not just abuse. An Australian
    # tester on hydra v1.8.7 (which moved porn traffic from WARP to the node exit)
    # got bursts of `failed to create session: connection reset by peer` against
    # JP002 mid-video: a media page opens dozens of parallel segment fetches, they
    # all hash to the caller's single bucket, and 12mbit is under what adaptive
    # bitrate asks for. This stays a per-client-IP abuse guard, just a roomier one.
    #
    # BURST MOVES WITH CEIL -- it is not decoration. HTB can only emit `burst`
    # bytes per timer tick, so a ceiling raised without it simply never gets
    # reached (burst >= ceil/HZ; at HZ=250, 36mbit needs >=18k, 12mbit needs >=6k).
    # Leaving burst at 16k/6k would have made this change a no-op for download and
    # a partial one for upload. Kept just above the minimum, not far above: an
    # oversized burst lets a flow overshoot ceil on each tick.
    #
    # Aggregate stays safe: the 256 buckets' guaranteed rates total
    # 256 x 1152kbit = 295mbit down / 98mbit up, both still well under LINE, so
    # the borrow-up-to-ceil behaviour is unchanged -- a single client can burst to
    # 36mbit when the node is idle and falls back to its fair share under load.
    # LINE and DIV deliberately unchanged.
    #
    # Old values preserved:
    #   DOWN=12mbit; UP=4mbit; LINE=1000mbit
    #   DOWN_RATE=384kbit; UP_RATE=128kbit; DOWN_BURST=16k; UP_BURST=6k; DIV=256
    DOWN=36mbit; UP=12mbit; LINE=1000mbit
    DOWN_RATE=1152kbit; UP_RATE=384kbit; DOWN_BURST=48k; UP_BURST=18k; DIV=256

    for m in sch_htb sch_fq_codel cls_u32 act_mirred ifb; do modprobe "$m" 2>/dev/null; done

    tear_down() {
        tc qdisc del dev "$DEV" root 2>/dev/null
        tc qdisc del dev "$DEV" ingress 2>/dev/null
        tc qdisc del dev ifb0 root 2>/dev/null
    }

    # persist an off-switch so ops can revert by hand without this script.
    # NOTE(2026-08-10, AU001 canary): generated via an UNQUOTED here-doc that
    # bakes the resolved $DEV in, NOT `echo`. This script is #!/bin/dash and
    # dash's echo is XSI — it turns the sed backref \1 into octal \001, which
    # corrupted the device-detection line of the old echo-built off-switch and
    # left eth0's tree un-removable (ifb0 gone but ingress mirred still pointing
    # at it → dropped client uploads). Hard-coding $DEV removes the sed entirely,
    # same as tear_down(), so ops revert is always reliable. \$PATH is escaped so
    # it stays literal in the generated file.
    cat > /usr/local/sbin/node-ratelimit-off.sh 2>/dev/null <<OFF
#!/bin/sh
export PATH=/usr/sbin:/sbin:/usr/bin:/bin:\$PATH
tc qdisc del dev $DEV root 2>/dev/null
tc qdisc del dev $DEV ingress 2>/dev/null
tc qdisc del dev ifb0 root 2>/dev/null
ip link set ifb0 down 2>/dev/null
ip link del ifb0 2>/dev/null
echo shaping-removed
OFF
    chmod +x /usr/local/sbin/node-ratelimit-off.sh 2>/dev/null

    tear_down   # idempotent clean before rebuild

    # ---- A. egress (download): hash by client dst IP, tcp sport 443 -----------
    tc qdisc add dev "$DEV" root handle 1: htb default 9999 r2q 100
    tc class add dev "$DEV" parent 1: classid 1:1 htb rate "$LINE" ceil "$LINE"
    tc class add dev "$DEV" parent 1:1 classid 1:9999 htb rate "$LINE" ceil "$LINE"
    i=0; while [ "$i" -lt "$DIV" ]; do cid=$((256+i))
      tc class add dev "$DEV" parent 1:1 classid 1:$cid htb rate "$DOWN_RATE" ceil "$DOWN" burst "$DOWN_BURST" cburst "$DOWN_BURST" quantum 1514
      tc qdisc add dev "$DEV" parent 1:$cid handle $cid: fq_codel; i=$((i+1)); done
    tc filter add dev "$DEV" parent 1:0 protocol ip handle 10: u32 divisor "$DIV"
    tc filter add dev "$DEV" parent 1:0 protocol ip prio 1 u32 match ip protocol 6 0xff match ip sport 443 0xffff hashkey mask 0x000000ff at 16 link 10:
    i=0; while [ "$i" -lt "$DIV" ]; do h=$(printf '%x' "$i")
      tc filter add dev "$DEV" parent 1:0 protocol ip prio 1 u32 ht 10:$h: match ip dst 0.0.0.0/0 flowid 1:$((256+i)); i=$((i+1)); done

    # ---- B. ingress (upload) -> ifb0: hash by client src IP, tcp dport 443 ----
    ip link add ifb0 type ifb 2>/dev/null || true
    ip link set ifb0 up
    tc qdisc add dev "$DEV" handle ffff: ingress
    tc filter add dev "$DEV" parent ffff: protocol ip prio 1 u32 match ip protocol 6 0xff match ip dport 443 0xffff action mirred egress redirect dev ifb0
    tc qdisc add dev ifb0 root handle 1: htb default 9999 r2q 100
    tc class add dev ifb0 parent 1: classid 1:1 htb rate "$LINE" ceil "$LINE"
    tc class add dev ifb0 parent 1:1 classid 1:9999 htb rate "$LINE" ceil "$LINE"
    i=0; while [ "$i" -lt "$DIV" ]; do cid=$((256+i))
      tc class add dev ifb0 parent 1:1 classid 1:$cid htb rate "$UP_RATE" ceil "$UP" burst "$UP_BURST" cburst "$UP_BURST" quantum 1514
      tc qdisc add dev ifb0 parent 1:$cid handle $cid: fq_codel; i=$((i+1)); done
    tc filter add dev ifb0 parent 1:0 protocol ip handle 10: u32 divisor "$DIV"
    tc filter add dev ifb0 parent 1:0 protocol ip prio 1 u32 match ip protocol 6 0xff match ip dport 443 0xffff hashkey mask 0x000000ff at 12 link 10:
    i=0; while [ "$i" -lt "$DIV" ]; do h=$(printf '%x' "$i")
      tc filter add dev ifb0 parent 1:0 protocol ip prio 1 u32 ht 10:$h: match ip src 0.0.0.0/0 flowid 1:$((256+i)); i=$((i+1)); done

    # ---- health gate: keep only if node is healthy + full tree; else revert ---
    EG=fail; curl -fsS --max-time 8 -o /dev/null https://1.1.1.1 && EG=ok
    SB=$(systemctl is-active sing-box 2>/dev/null)
    ECLS=$(tc class show dev "$DEV" 2>/dev/null | grep -c 'class htb')
    ICLS=$(tc class show dev ifb0 2>/dev/null | grep -c 'class htb')
    EFIL=$(tc filter show dev "$DEV" 2>/dev/null | grep -c 'flowid')
    IFIL=$(tc filter show dev ifb0 2>/dev/null | grep -c 'flowid')
    L443=$(ss -tlnp 2>/dev/null | grep -c ':443')
    # NOTE(2026-08-11, review hardening): also assert the UPLOAD path is live, not
    # just structurally present. The structural counts (ICLS/IFIL) pass even if ifb0
    # is admin-DOWN or the ingress->ifb0 redirect is missing, which would blackhole
    # client uploads (tcp dport 443) while the gate stays green. Near-impossible to
    # reach in steady state, but the check is free.
    #   * IFUP: match the IFF_UP flag in <...>, NOT `state UP` — ifb virtual devices
    #     report operstate UNKNOWN even when administratively up, so `state UP` would
    #     false-fail a healthy apply and silently un-shape the whole fleet.
    #   * MIR: the $DEV ingress -> ifb0 mirred redirect must be installed.
    IFUP=$(ip link show ifb0 2>/dev/null | grep -cE '[<,]UP[,>]')
    MIR=$(tc filter show dev "$DEV" parent ffff: 2>/dev/null | grep -c mirred)
    if [ "$EG" = ok ] && [ "$SB" = active ] && [ "$ECLS" -ge 257 ] && [ "$ICLS" -ge 257 ] \
       && [ "$EFIL" -ge 256 ] && [ "$IFIL" -ge 256 ] && [ "$L443" -ge 1 ] \
       && [ "$IFUP" -ge 1 ] && [ "$MIR" -ge 1 ]; then
        log "shaping: applied per-IP $DOWN/$UP on $DEV (egress=$EG singbox=$SB)"
    else
        log "shaping: health gate FAILED (egress=$EG singbox=$SB ecls=$ECLS icls=$ICLS ifup=$IFUP mir=$MIR), reverting to un-shaped"
        tear_down
    fi
    return 0
}
apply_shaping

# ── 3. ACME credential re-sync ────────────────────────────────────────────────
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
