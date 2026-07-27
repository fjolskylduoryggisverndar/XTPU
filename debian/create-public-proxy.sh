#!/bin/dash

set -efu
export LC_ALL=C
unset SSLKEYLOGFILE

# UPSTREAM format: name|parser|URL; supported URL templates follow.
UPSTREAM='databay|csv5|https://databay.com/api/v1/proxy-list?format=csv&country={COUNTRY}&limit=1000
proxyscrape|text|https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&proxy_format=protocolipport&format=text&country={country}
proxifly|text|https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/countries/{COUNTRY}/data.txt
geonode|json-page|https://proxylist.geonode.com/api/proxy-list?country={COUNTRY}&limit=500&page={page}&sort_by=lastChecked&sort_type=desc
proxylister|csv3|https://proxylister.com/api/v1/proxies/export?format=csv&country_code={COUNTRY}&limit=500
iplocate|text|https://raw.githubusercontent.com/iplocate/free-proxy-list/main/countries/{COUNTRY}/proxies.txt
hproxy|csv3|https://hproxy.com/api/proxy-list?format=csv&country={COUNTRY}&recent=true&limit=10000
freeapiproxies|json-protocol|https://freeapiproxies.azurewebsites.net/proxyapi?country={COUNTRY}&type={protocol}
freeproxyworld|html-page|https://www.freeproxy.world/?country={COUNTRY}&page={page}'

JOBS=24
CONNECT_TIMEOUT=4
MAX_TIME=8
TEST_URL=https://www.google.com/generate_204
USER_AGENT='Mozilla/5.0 (compatible; create-public-proxy/1.0)'

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

log() {
    echo "[INFO] $*" >&2
}

count() {
    awk 'NF { count++ } END { print count + 0 }'
}

unique_proxy() {
    awk 'NF && !seen[$0]++'
}

for CMD in awk curl sed tr; do
    command -v "$CMD" >/dev/null 2>&1 || die "Command not found: $CMD"
done

[ "$#" -eq 1 ] || {
    echo "Usage: $0 <country-code>" >&2
    echo "Example: curl -fsSL https://bit.ly/create-public-proxy | dash -s -- ph" >&2
    exit 1
}

COUNTRY=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
case "$COUNTRY" in
    [A-Z][A-Z]) ;;
    *) die "Country code must contain two ASCII letters" ;;
esac
COUNTRY_LOWER=$(printf '%s' "$COUNTRY" | tr '[:upper:]' '[:lower:]')

FETCHED=0
RESPONSE=

expand_url() {
    printf '%s' "$1" | sed \
        -e "s/{country}/${COUNTRY_LOWER}/g" \
        -e "s/{COUNTRY}/${COUNTRY}/g" \
        -e "s/{protocol}/${2-}/g" \
        -e "s/{page}/${3-}/g"
}

normalize() {
    awk -F, -v mode="$1" '
        function clean(value) {
            gsub(/\r/, "", value)
            gsub(/^[[:space:]"]+/, "", value)
            gsub(/[[:space:]"]+$/, "", value)
            return value
        }

        function emit(addr, port, protocol, octets, count, i) {
            addr = clean(addr)
            port = clean(port)
            protocol = toupper(clean(protocol))

            count = split(addr, octets, ".")
            if (count != 4 ||
                port !~ /^[0-9]+$/ ||
                (port + 0) < 1 ||
                (port + 0) > 65535 ||
                protocol !~ /^(HTTP|HTTPS|SOCKS4|SOCKS5)$/) {
                return
            }

            for (i = 1; i <= 4; i++) {
                if (octets[i] !~ /^[0-9]+$/ ||
                    (octets[i] + 0) > 255) {
                    return
                }
            }
            print addr "," port "," protocol
        }

        function emit_protocols(addr, port, list, protocols, count, i) {
            gsub(/\|/, ",", list)
            count = split(list, protocols, ",")
            for (i = 1; i <= count; i++) {
                emit(addr, port, protocols[i])
            }
        }

        function parse_json(line, addr, port, list, token) {
            if (!match(line, /"ip":"[^"]+"/)) {
                return
            }
            addr = substr(line, RSTART + 6, RLENGTH - 7)

            if (!match(line, /"port":"?[0-9]+"?/)) {
                return
            }
            port = substr(line, RSTART, RLENGTH)
            sub(/^"port":/, "", port)
            gsub(/"/, "", port)

            if (match(line, /"protocols":\[[^]]*\]/)) {
                list = substr(line, RSTART, RLENGTH)
                sub(/^"protocols":\[/, "", list)
                sub(/\]$/, "", list)
            } else if (match(line, /"type":"[^"]+"/)) {
                list = substr(line, RSTART, RLENGTH)
                sub(/^"type":/, "", list)
            } else {
                return
            }
            emit_protocols(addr, port, list)
        }

        mode == "csv3" {
            emit_protocols($1, $2, $3)
            next
        }

        mode == "csv5" {
            emit_protocols($1, $2, $5)
            next
        }

        mode == "text" {
            line = clean($0)
            if (line == "" || line ~ /^#/) {
                next
            }

            addr = ""
            port = ""
            protocol = "HTTP"
            endpoint = line

            if (index(line, "://")) {
                position = index(line, "://")
                protocol = substr(line, 1, position - 1)
                endpoint = substr(line, position + 3)
            } else if (index(line, ",")) {
                split(line, fields, ",")
                emit(fields[1], fields[2], fields[3])
                next
            }

            if (split(endpoint, fields, ":") == 2) {
                emit(fields[1], fields[2], protocol)
            }
            next
        }

        mode == "json" {
            count = split($0, objects, /},\{/)
            for (i = 1; i <= count; i++) {
                parse_json(objects[i])
            }
            next
        }

        mode == "html" {
            if ($0 ~ /<tr>/) {
                addr = ""
                port = ""
                protocol_count = 0
            }
            if ($0 ~ /font-weight: 500;">/) {
                addr = $0
                sub(/^.*font-weight: 500;">/, "", addr)
                sub(/<.*$/, "", addr)
            }
            if ($0 ~ /href="\/\?port=[0-9]+"/) {
                port = $0
                sub(/^.*href="\/\?port=/, "", port)
                sub(/".*$/, "", port)
            }
            if ($0 ~ /href="\/\?type=(http|https|socks4|socks5)"/) {
                protocol = $0
                sub(/^.*href="\/\?type=/, "", protocol)
                sub(/".*$/, "", protocol)
                protocols[++protocol_count] = protocol
            }
            if ($0 ~ /<\/tr>/) {
                for (i = 1; i <= protocol_count; i++) {
                    emit(addr, port, protocols[i])
                }
            }
        }
    '
}

fetch_one() {
    local NAME=$1 FORMAT=$2 URL=$3 PARSED

    if RESPONSE=$(curl -q -fsL \
        --retry 2 \
        --retry-delay 1 \
        --retry-max-time 12 \
        --connect-timeout 10 \
        --max-time 45 \
        -A "$USER_AGENT" \
        "$URL"); then
        PARSED=$(printf '%s\n' "$RESPONSE" | normalize "$FORMAT") ||
            die "Unable to parse $NAME"
        FETCHED=$((FETCHED + 1))
        log "$NAME"
        [ -z "$PARSED" ] || printf '%s\n' "$PARSED"
        return 0
    fi

    echo "[WARN] $NAME unavailable" >&2
    return 1
}

fetch_pages() {
    local NAME=$1 FORMAT=$2 TEMPLATE=$3 PAGE=1 PAGES=1
    local ID TOTAL

    while [ "$PAGE" -le "$PAGES" ]; do
        ID="$NAME-$PAGE"
        fetch_one "$ID" "$FORMAT" \
            "$(expand_url "$TEMPLATE" "" "$PAGE")" || break

        if [ "$PAGE" -eq 1 ]; then
            if [ "$FORMAT" = json ]; then
                TOTAL=$(printf '%s\n' "$RESPONSE" |
                    sed -n 's/.*],"total":\([0-9][0-9]*\),.*/\1/p')
                case "$TOTAL" in
                    '' | *[!0-9]*) PAGES=1 ;;
                    *) PAGES=$(((TOTAL + 499) / 500)) ;;
                esac
            else
                PAGES=$(
                    printf '%s\n' "$RESPONSE" |
                        sed -n \
                            "s/.*country=${COUNTRY}&amp;page=\\([0-9][0-9]*\\).*/\\1/p" |
                        awk '$1 > max { max = $1 } END { print max ? max : 1 }'
                )
                [ "$PAGES" -le 100 ] || PAGES=100
            fi
        fi
        PAGE=$((PAGE + 1))
    done
}

fetch_all() {
    local OLD_IFS ENTRY NAME REST FORMAT URL PROTOCOL

    OLD_IFS=$IFS
    IFS='
'
    set -- $UPSTREAM
    IFS=$OLD_IFS

    for ENTRY do
        NAME=${ENTRY%%|*}
        REST=${ENTRY#*|}
        FORMAT=${REST%%|*}
        URL=${REST#*|}

        case "$FORMAT" in
            csv3 | csv5 | text)
                fetch_one "$NAME" "$FORMAT" "$(expand_url "$URL")" || :
                ;;
            json-page)
                fetch_pages "$NAME" json "$URL"
                ;;
            html-page)
                fetch_pages "$NAME" html "$URL"
                ;;
            json-protocol)
                for PROTOCOL in http socks4 socks5; do
                    fetch_one "$NAME-$PROTOCOL" json \
                        "$(expand_url "$URL" "$PROTOCOL")" || :
                done
                ;;
            *)
                die "Unknown upstream format: $FORMAT"
                ;;
        esac
    done
    [ "$FETCHED" -gt 0 ] || die "All upstreams failed"
}

RAW=$(fetch_all)
CANDIDATES=$(printf '%s\n' "$RAW" | unique_proxy)
TOTAL=$(printf '%s\n' "$CANDIDATES" | count)
[ "$TOTAL" -gt 0 ] || die "No proxies found for $COUNTRY"
log "Testing $TOTAL proxies for $COUNTRY"

check_proxy() {
    local LINE=$1 REST ADDR PORT PROTOCOL SCHEME CODE

    ADDR=${LINE%%,*}
    REST=${LINE#*,}
    PORT=${REST%%,*}
    PROTOCOL=${LINE##*,}

    case "$PROTOCOL" in
        HTTP | HTTPS) SCHEME=http ;;
        SOCKS4) SCHEME=socks4a ;;
        SOCKS5) SCHEME=socks5h ;;
        *) return 0 ;;
    esac

    CODE=$(
        curl -q -x "$SCHEME://$ADDR:$PORT" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            -s \
            -o /dev/null \
            -w '%{http_code}' \
            -A "$USER_AGENT" \
            "$TEST_URL" 2>/dev/null
    ) || return 0

    [ "$CODE" = 204 ] && echo "$LINE"
    return 0
}

check_pass() {
    local INPUT=$1 LABEL=$2 OUTPUT INPUT_COUNT RESULT_COUNT

    OUTPUT=$(
        printf '%s\n' "$INPUT" |
            {
                RUNNING=0
                while IFS= read -r LINE; do
                    [ -n "$LINE" ] || continue
                    check_proxy "$LINE" &
                    RUNNING=$((RUNNING + 1))
                    if [ "$RUNNING" -ge "$JOBS" ]; then
                        wait
                        RUNNING=0
                    fi
                done
                [ "$RUNNING" -eq 0 ] || wait
            } |
            unique_proxy
    )

    INPUT_COUNT=$(printf '%s\n' "$INPUT" | count)
    RESULT_COUNT=$(printf '%s\n' "$OUTPUT" | count)
    log "$LABEL: $RESULT_COUNT/$INPUT_COUNT"
    printf '%s' "$OUTPUT"
}

PASS1=$(check_pass "$CANDIDATES" "First check")
PASS2=$(check_pass "$PASS1" "Confirmation")

echo 'addr,port,protocol'
[ -z "$PASS2" ] || printf '%s\n' "$PASS2"
