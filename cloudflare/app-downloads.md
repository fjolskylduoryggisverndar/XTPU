# app-downloads

One Cloudflare Worker serving the Android and Windows downloads for every
brand, from that brand's own domain.

    dl.buddhajump.xyz/android   ->  302  current APK, via a GitHub mirror
    dl.88888vpn.com/windows     ->  302  current Windows zip
    dl.<brand>/                 ->  a plain index of what is available

## Why not a link shortener

The published links used to be bit.ly. Two problems: bit.ly's own domain does
not resolve in mainland China, and the GitHub asset host it pointed at does not
either — so the "censorship-resistant" link was blocked at both ends. Worse, the
account holding those links was not ours, so they could not be repointed; every
one of them had rotted to a 404 while still being advertised on the sites.

Serving from `dl.<brand-domain>` fixes the ownership problem: the hostname is
ours, the destination is swappable without touching any site, and each brand
keeps its own domain (no cross-brand leakage).

## Mirrors

The default destination is wrapped in a GitHub proxy, because the raw asset
host is what actually gets blocked. Overrides for debugging:

    ?direct=1   skip the mirror, go straight to GitHub
    ?mirror=1   use the second mirror in the list

## Updating after a release

The asset URLs are baked into the Worker, so a new build needs a redeploy:

    export CF_TOKEN=$(security find-generic-password -s fjosky.cloudflare.fjolsky -w)
    ./create-cloudflare-app-downloads.sh

The websites themselves need no change — they read the download links from
hydra (`GET /v1/public/pkg` with the room hash), which points at these
`dl.<brand>` URLs, so the indirection holds across releases.
