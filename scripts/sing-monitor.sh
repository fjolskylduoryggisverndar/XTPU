#!/bin/dash
#
# sing-box configuration monitor (node side), metering edition.
#
# VERBATIM copy of the template hydra's provisioner installs at
# /usr/local/bin/sing-monitor.sh (hydra src/utils/server.rs,
# install_monitor_script, v1.8.12), so a node provisioned by hydra and a node
# upgraded in place by XTPU's node-daily-maintenance.sh Job 4 run the same
# script. Keep it that way: when hydra's template changes, re-copy it here and
# re-apply the single XTPU-only addition below, which is tagged
# [added v3 2026-09-05] and consists of the `harvest` entry point in main().
#
# Why the entry point: Job 4 must harvest the in-memory per-user counters
# right before its daily `apt-get install sing-box` (the package postinst
# restarts the service and zeroes them). `sing-monitor.sh harvest` does only
# that, under the monitor's own lock, so pending.json is never written by two
# processes at once. (Invoking the plain hydra template with the same argument
# is harmless: it ignores $1 and runs a normal heartbeat cycle, which also
# harvests first.)
#
# The %PLACEHOLDER% values are substituted at install time. Job 4 copies them
# out of the previously installed script (hydra rendered them from its own
# settings), so nothing here hard-codes an API host.

API_SERVER="%API_SERVER%"
CONFIG_PATH="%CONFIG_PATH%"
USERS_PATH="%USERS_PATH%"
SCHEME_PATH="%SCHEME_PATH%"
TEMP_USERS="%TEMP_USERS%"
TEMP_SCHEME="%TEMP_SCHEME%"
LOCK_FILE="%LOCK_FILE%"
CONFIG_BACKUP="${CONFIG_PATH}.backup"
USERS_BACKUP="${USERS_PATH}.backup"
SCHEME_BACKUP="${SCHEME_PATH}.backup"
CONFIG_NEW="${CONFIG_PATH}.new"

log_message() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

cleanup_lock() {
    rm -f "$LOCK_FILE"
}

# [added v1.8.12 2026-09-05] Per-user traffic metering (hydra account_usage).
# The node harvests sing-box's per-user counters through the v2ray_api stats
# service (QueryStats with reset) using a small gRPC client shipped by the
# fleet maintenance script (XTPU) as STATS_BIN, merges the deltas into
# PENDING_PATH (at-least-once: cleared only after the API acknowledged them),
# and rides them along on the existing /users heartbeat body as
# {"users":{"<uuid>":{"up":N,"down":N}},"batch_seq":N}. Everything here is
# fail-open: no STATS_BIN, no experimental.v2ray_api section in the config,
# or any error -> no users field -> the heartbeat is byte-identical to before.
# This template NEVER adds the experimental section itself: the official
# sing-box package is built without with_v2ray_api and refuses such a config
# at `check`, which would freeze the user list. XTPU adds the section only
# after it has installed and verified a binary that carries the tag.
STATS_BIN="/usr/local/bin/sing-stats"
PENDING_DIR="/var/lib/sing-monitor"
PENDING_PATH="${PENDING_DIR}/pending.json"
PENDING_TMP="${PENDING_DIR}/pending.tmp.json"

ensure_pending() {
    [ -d "$PENDING_DIR" ] || sudo mkdir -p "$PENDING_DIR" || return 1
    if ! jq -e 'type == "object"' "$PENDING_PATH" >/dev/null 2>&1; then
        # seq starts at the epoch second so a lost/fresh pending file can never
        # restart below a seq hydra has already seen (it bumps <= once per 10s).
        printf '{"seq":%s,"users":{}}' "$(date +%s)" | sudo tee "$PENDING_PATH" > /dev/null || return 1
    fi
}

harvest_stats() {
    [ -x "$STATS_BIN" ] || return 0
    LISTEN=$(jq -r '.experimental.v2ray_api.listen // empty' "$CONFIG_PATH" 2>/dev/null)
    [ -n "$LISTEN" ] || return 0
    DELTA=$("$STATS_BIN" -listen "$LISTEN" -reset 2>/dev/null) || return 0
    printf '%s' "$DELTA" | jq -e 'type == "object"' >/dev/null 2>&1 || return 0
    ensure_pending || return 0
    MERGED=$(jq --argjson d "$DELTA" '.users = (reduce ($d | to_entries[]) as $e ((.users // {}); .[$e.key] = {up: ((.[$e.key].up // 0) + ($e.value.up // 0)), down: ((.[$e.key].down // 0) + ($e.value.down // 0))}))' "$PENDING_PATH" 2>/dev/null) || return 0
    [ -n "$MERGED" ] || return 0
    printf '%s' "$MERGED" | sudo tee "$PENDING_TMP" > /dev/null || return 0
    sudo mv "$PENDING_TMP" "$PENDING_PATH" 2>/dev/null || return 0
}

pending_users() {
    jq -c '(.users // {}) | with_entries(select(((.value.up // 0) > 0) or ((.value.down // 0) > 0)))' "$PENDING_PATH" 2>/dev/null || printf '{}'
}

pending_seq() {
    jq -r '.seq // 0' "$PENDING_PATH" 2>/dev/null || printf '0'
}

ack_pending() {
    ACKED=$(jq '.users = {} | .seq = ((.seq // 0) + 1)' "$PENDING_PATH" 2>/dev/null) || return 0
    [ -n "$ACKED" ] || return 0
    printf '%s' "$ACKED" | sudo tee "$PENDING_TMP" > /dev/null || return 0
    sudo mv "$PENDING_TMP" "$PENDING_PATH" 2>/dev/null || return 0
}

# [changed v1.8.12 2026-09-05] harvests first, then sends pending user deltas
# + batch_seq in the same stats body; on a valid reply the pending batch is
# acknowledged. Old body:
#   BYTES=$(awk -F'[: ]+' '$2!="lo" && NR>2 {rx+=$3; tx+=$11} END{print rx" "tx}' /proc/net/dev 2>/dev/null || echo "0 0")
#   RX=${BYTES%% *}; TX=${BYTES##* }
#   CONNS=$(ss -H state established '( sport = :443 )' 2>/dev/null | wc -l 2>/dev/null || echo 0)
#   LOAD1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0); NCPU=$(nproc 2>/dev/null || echo 1)
#   STATS=$(printf '{"rx":%s,"tx":%s,"conns":%s,"load1":%s,"ncpu":%s}' "${RX:-0}" "${TX:-0}" "${CONNS:-0}" "${LOAD1:-0}" "${NCPU:-1}")
#   RESPONSE=$(curl -sSX POST -H 'Content-Type: application/json' --data "$STATS" "$API_SERVER/users")
#   DECODED=$(printf '%s' "$RESPONSE" | jq -r '.data.config' | base64 -d)
#   if [ -z "$DECODED" ]; then
#       return 1
#   fi
#   if ! printf '%s' "$DECODED" | jq -e '.users | type == "array" and length > 0' >/dev/null 2>&1; then
#       return 1
#   fi
#   printf '%s' "$DECODED" > "$TEMP_USERS"
fetch_users() {
    harvest_stats
    BYTES=$(awk -F'[: ]+' '$2!="lo" && NR>2 {rx+=$3; tx+=$11} END{print rx" "tx}' /proc/net/dev 2>/dev/null || echo "0 0")
    RX=${BYTES%% *}; TX=${BYTES##* }
    CONNS=$(ss -H state established '( sport = :443 )' 2>/dev/null | wc -l 2>/dev/null || echo 0)
    LOAD1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0); NCPU=$(nproc 2>/dev/null || echo 1)
    USERS_DELTA='{}'
    BATCH_SEQ=0
    if [ -f "$PENDING_PATH" ]; then
        USERS_DELTA=$(pending_users)
        BATCH_SEQ=$(pending_seq)
    fi
    printf '%s' "$USERS_DELTA" | jq -e 'type == "object"' >/dev/null 2>&1 || USERS_DELTA='{}'
    case "$BATCH_SEQ" in
        ''|*[!0-9]*) BATCH_SEQ=0 ;;
    esac
    STATS=$(printf '{"rx":%s,"tx":%s,"conns":%s,"load1":%s,"ncpu":%s,"users":%s,"batch_seq":%s}' "${RX:-0}" "${TX:-0}" "${CONNS:-0}" "${LOAD1:-0}" "${NCPU:-1}" "$USERS_DELTA" "$BATCH_SEQ")
    RESPONSE=$(curl -sSX POST -H 'Content-Type: application/json' --data "$STATS" "$API_SERVER/users")
    DECODED=$(printf '%s' "$RESPONSE" | jq -r '.data.config' | base64 -d)
    if [ -z "$DECODED" ]; then
        return 1
    fi
    if ! printf '%s' "$DECODED" | jq -e '.users | type == "array" and length > 0' >/dev/null 2>&1; then
        return 1
    fi
    printf '%s' "$DECODED" > "$TEMP_USERS"
    # A valid reply means hydra processed the body: the batch is delivered.
    if [ "$USERS_DELTA" != "{}" ]; then
        ack_pending
    fi
}

fetch_scheme() {
    RESPONSE=$(curl -sSX POST "$API_SERVER/scheme")
    DECODED=$(printf '%s' "$RESPONSE" | jq -r '.data.config')
    if [ -z "$DECODED" ] || [ "$DECODED" = "null" ]; then
        return 1
    fi
    SCHEME_VALUE=$(printf '%s' "$DECODED" | base64 -d)
    if [ -z "$SCHEME_VALUE" ]; then
        return 1
    fi
    if ! printf '%s' "$SCHEME_VALUE" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        return 1
    fi
    printf '%s' "$SCHEME_VALUE" > "$TEMP_SCHEME"
}

users_differ() {
    if jq -e '.inbounds[0].users == null or .inbounds[0].users == []' "$CONFIG_PATH" > /dev/null 2>&1; then
        return 0
    fi
    ! cmp -s "$TEMP_USERS" "$USERS_PATH"
}

scheme_differ() {
    ! cmp -s "$TEMP_SCHEME" "$SCHEME_PATH"
}

update_config() {
    cp "$CONFIG_PATH" "$CONFIG_BACKUP"
    cp "$USERS_PATH" "$USERS_BACKUP"

    # [changed v1.8.12 2026-09-05] when (and ONLY when) the config already has
    # an experimental.v2ray_api.stats section, its `users` name list is
    # refreshed from the new inbound users in the same edit, so every member
    # is metered. A config without the section is left exactly as before
    # (never added here -- see the note at the top). Old line:
    #   NEW_CONFIG=$(jq --slurpfile users "$TEMP_USERS" '.inbounds[0].users = $users[0].users' "$CONFIG_PATH")
    NEW_CONFIG=$(jq --slurpfile users "$TEMP_USERS" '.inbounds[0].users = $users[0].users | if .experimental.v2ray_api.stats != null then .experimental.v2ray_api.stats.users = [.inbounds[0].users[] | select(.name != null) | .name] else . end' "$CONFIG_PATH")
    if [ $? -ne 0 ] || [ -z "$NEW_CONFIG" ]; then
        return 1
    fi
    if ! printf '%s' "$NEW_CONFIG" | jq -e '.inbounds[0].users | type == "array"' >/dev/null 2>&1; then
        return 1
    fi

    printf '%s' "$NEW_CONFIG" | sudo tee "$CONFIG_NEW" > /dev/null || return 1
    [ -s "$CONFIG_NEW" ] || return 1
    sudo mv "$CONFIG_NEW" "$CONFIG_PATH" || return 1
    cp "$TEMP_USERS" "$USERS_PATH"
}

update_scheme() {
    cp "$CONFIG_PATH" "$CONFIG_BACKUP"
    cp "$SCHEME_PATH" "$SCHEME_BACKUP"

    SCHEME_VALUE=$(cat "$TEMP_SCHEME")
    if [ -z "$SCHEME_VALUE" ]; then
        return 1
    fi

    NEW_CONFIG=$(jq --argjson scheme "$SCHEME_VALUE" '.inbounds[0].padding_scheme = $scheme' "$CONFIG_PATH")
    if [ $? -ne 0 ] || [ -z "$NEW_CONFIG" ]; then
        return 1
    fi
    if ! printf '%s' "$NEW_CONFIG" | jq -e '.inbounds[0]' >/dev/null 2>&1; then
        return 1
    fi

    printf '%s' "$NEW_CONFIG" | sudo tee "$CONFIG_NEW" > /dev/null || return 1
    [ -s "$CONFIG_NEW" ] || return 1
    sudo mv "$CONFIG_NEW" "$CONFIG_PATH" || return 1
    cp "$TEMP_SCHEME" "$SCHEME_PATH"
}

acme_differ() {
    WANT=$(jq -r '.acme_token // empty' "$TEMP_USERS")
    [ -n "$WANT" ] || return 1
    HAVE=$(jq -r '.inbounds[0].tls.acme.dns01_challenge.api_token // empty' "$CONFIG_PATH")
    [ "$WANT" != "$HAVE" ]
}

update_acme() {
    cp "$CONFIG_PATH" "$CONFIG_BACKUP"

    WANT=$(jq -r '.acme_token // empty' "$TEMP_USERS")
    [ -n "$WANT" ] || return 1

    NEW_CONFIG=$(jq --arg t "$WANT" '.inbounds[0].tls.acme.dns01_challenge.api_token = $t' "$CONFIG_PATH")
    if [ $? -ne 0 ] || [ -z "$NEW_CONFIG" ]; then
        return 1
    fi
    if ! printf '%s' "$NEW_CONFIG" | jq -e '.inbounds[0].tls.acme.dns01_challenge.api_token | type == "string"' >/dev/null 2>&1; then
        return 1
    fi

    printf '%s' "$NEW_CONFIG" | sudo tee "$CONFIG_NEW" > /dev/null || return 1
    [ -s "$CONFIG_NEW" ] || return 1
    sudo mv "$CONFIG_NEW" "$CONFIG_PATH" || return 1
}

validate_config() {
    sing-box check -c "$CONFIG_PATH" 2>/dev/null
}

restart_service() {
    log_message "Configuration changed. Restarting sing-box service..."
    if sudo systemctl restart sing-box; then
        log_message "Service restarted successfully"
        return 0
    else
        log_message "Failed to restart service"
        return 1
    fi
}

check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        PID=$(cat "$LOCK_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            LOCK_TIME=$(stat -c %Y "$LOCK_FILE")
            CURRENT_TIME=$(date +%s)
            if [ $((CURRENT_TIME - LOCK_TIME)) -gt 300 ]; then
                log_message "Found stale lock file. Removing..."
                cleanup_lock
            else
                log_message "Another instance is running (PID: $PID). Exiting."
                exit 1
            fi
        else
            log_message "Found orphaned lock file. Removing..."
            cleanup_lock
        fi
    fi
}

rollback_config() {
    log_message "Rolling back to previous configuration..."
    cp "$CONFIG_BACKUP" "$CONFIG_PATH"
    cp "$USERS_BACKUP" "$USERS_PATH"
    cp "$SCHEME_BACKUP" "$SCHEME_PATH"
    restart_service
}

main() {
    trap cleanup_lock EXIT INT TERM

    check_lock
    echo $$ > "$LOCK_FILE"

    # [added v3 2026-09-05] XTPU-only: `sing-monitor.sh harvest` folds the
    # current counters into pending.json under the lock and exits. Used by
    # node-daily-maintenance.sh Job 4 right before the apt upgrade.
    if [ "$1" = "harvest" ]; then
        harvest_stats
        exit 0
    fi

    NEED_RESTART=0

    fetch_users || exit 1
    fetch_scheme || exit 1

    if users_differ; then
        update_config || exit 1
        NEED_RESTART=1
    fi

    if scheme_differ; then
        update_scheme || exit 1
        NEED_RESTART=1
    fi

    # The certificate renewal credential. /server/config is fetched once at
    # install and never again, so without this a rotated Cloudflare token never
    # reaches a running node: ACME renewal fails ~30 days before expiry and the
    # node stops serving TLS. Failing to apply it must NOT take the node down,
    # so unlike users/scheme this one only warns.
    if acme_differ; then
        if update_acme; then
            NEED_RESTART=1
        else
            log_message "Failed to update ACME token; keeping the existing one"
        fi
    fi

    if [ "$NEED_RESTART" -eq 1 ]; then
        if ! validate_config; then
            cp "$CONFIG_BACKUP" "$CONFIG_PATH"
            cp "$USERS_BACKUP" "$USERS_PATH"
            cp "$SCHEME_BACKUP" "$SCHEME_PATH"
            exit 1
        fi
        # [added v1.8.12 2026-09-05] the per-user counters live in sing-box's
        # memory and die with the restart: harvest them into pending first.
        harvest_stats
        restart_service || rollback_config
    fi
}

main "$@"
