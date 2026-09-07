#!/bin/bash
# Backfill the fjolsky-downloads R2 bucket with each brand's CURRENT release
# assets (android APK, windows zip, macOS dmg where one exists) and write the
# per-platform manifests the fjolsky-downloads Worker reads. Uses the R2 REST
# API directly (no wrangler): PUT /accounts/{id}/r2/buckets/{bucket}/objects/{key}.
#
# Usage:  backfill-r2-rest.sh <app> <ci-repo> <prefix>     (one brand)
#         backfill-r2-rest.sh all                            (all brands, 4 in parallel)
# Needs: keychain item fjosky.cloudflare.r2ci (Workers R2 Storage: Edit), gh auth.
set -u
A=72b71eab72f53b1f1e80ea435d40d9e1
BUCKET=fjolsky-downloads
WORK=${WORK:-/tmp/r2-backfill}
LOG=${LOG:-$WORK/backfill.log}
mkdir -p "$WORK"
R2=$(security find-generic-password -s fjosky.cloudflare.r2ci -w)
BRANDS='buddhajump BuddhaJumpApp/buddhajump-ci buddhajump
kamevpn fjolskylduoryggisverndar/kamevpn-ci kamevpn
00000vpn fjolskylduoryggisverndar/00000vpn-ci vpn00000
88888vpn fjolskylduoryggisverndar/88888vpn-ci vpn88888
goddessvpn BuddhaJumpApp/goddessvpn-ci goddessvpn
openbridge BuddhaJumpApp/openbridge-ci openbridge
libertygate BuddhaJumpApp/libertygate-ci libertygate
maskaura BuddhaJumpApp/maskaura-ci maskaura
aiglefree BuddhaJumpApp/aiglefree-ci aiglefree
maschvpn BuddhaJumpApp/maschvpn-ci maschvpn
ninjashield BuddhaJumpApp/ninjashield-ci ninjashield'

ctype() { case "$1" in android) echo application/vnd.android.package-archive;; windows) echo application/zip;; macos) echo application/x-apple-diskimage;; esac; }
asset_name() { case "$1" in android) echo "$2-android-universal-$3.apk";; windows) echo "$2-windows-amd64-$3.zip";; macos) echo "$2-macos-$3.dmg";; esac; }
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe="/"))' "$1"; }
put() { # key file content-type -> prints "ok" or error
  local key; key=$(enc "$1")
  curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/$A/r2/buckets/$BUCKET/objects/$key" \
    -H "Authorization: Bearer $R2" -H "Content-Type: $3" --upload-file "$2" -m 900 \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print("ok" if d.get("success") else "ERR "+str(d.get("errors"))[:200])
except Exception as e: print("ERR non-json")'
}
one() {
  local app=$1 repo=$2 prefix=$3 tag rel
  rel=$(gh api "repos/$repo/releases/latest") || { echo "[$app] gh api failed" >>"$LOG"; return 1; }
  tag=$(echo "$rel" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')
  echo "[$app] $repo $tag" >>"$LOG"
  for platform in android windows macos; do
    local name dl f size sha key ct r manifest
    name=$(asset_name "$platform" "$prefix" "$tag")
    dl=$(echo "$rel" | python3 -c 'import json,sys;n=sys.argv[1];print(next((a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"]==n),""))' "$name")
    if [ -z "$dl" ]; then echo "[$app] $platform: no asset $name (skip)" >>"$LOG"; continue; fi
    f="$WORK/$name"
    if [ ! -s "$f" ]; then curl -fsSL --retry 3 -m 1200 -o "$f.part" "$dl" && mv "$f.part" "$f" || { echo "[$app] $platform: download FAILED" >>"$LOG"; continue; }; fi
    size=$(stat -f%z "$f"); sha=$(shasum -a 256 "$f" | cut -d' ' -f1); ct=$(ctype "$platform"); key="$app/$tag/$name"
    r=$(put "$key" "$f" "$ct")
    if [ "$r" != "ok" ]; then echo "[$app] $platform: object put $r" >>"$LOG"; continue; fi
    manifest="$WORK/$app-$platform.json"
    python3 - "$manifest" "$tag" "$key" "$size" "$sha" "$ct" <<'EOF'
import json,sys,datetime
p,tag,key,size,sha,ct=sys.argv[1:]
json.dump({"tag":tag,"key":key,"size":int(size),"sha256":sha,"content_type":ct,"published_at":datetime.datetime.utcnow().replace(microsecond=0).isoformat()+"Z","source":"backfill-r2-rest.sh"},open(p,"w"))
EOF
    r=$(put "$app/latest/$platform.json" "$manifest" application/json)
    echo "[$app] $platform: $key ($((size/1048576)) MB) object=ok manifest=$r" >>"$LOG"
  done
  echo "[$app] done" >>"$LOG"
}
if [ "${1:-}" = "all" ]; then
  : >"$LOG"
  echo "$BRANDS" | xargs -P 4 -L 1 bash -c 'exec "$0" "$@"' "$0"
  echo "ALL DONE" >>"$LOG"
else
  one "$1" "$2" "$3"
fi
