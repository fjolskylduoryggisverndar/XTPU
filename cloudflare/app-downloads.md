# app-downloads

One Cloudflare Worker serving the Android, Windows and macOS downloads for every
brand, from that brand's own domain.

    dl.buddhajump.xyz/android   ->  current APK, streamed from R2 (falls back to a GitHub mirror)
    dl.88888vpn.com/windows     ->  current Windows zip
    dl.buddhajump.xyz/macos     ->  current notarized .dmg (brands whose CI builds one)
    dl.<brand>/                 ->  a plain index of what is available and where it comes from

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

[2026-09-07] Since the R2 change below, the mirror chain is only the FALLBACK
path; the flags above still work and `?src=github` forces that path.

## R2 (2026-09-07): the bytes are ours too

The Worker is bound to the R2 bucket `fjolsky-downloads` as `DOWNLOADS`. Layout:

    <app>/<tag>/<asset-filename>          the bytes (e.g. buddhajump/v1.7.3+178/buddhajump-android-universal-v1.7.3+178.apk)
    <app>/latest/<platform>.json          {"tag","key","size","sha256","content_type","published_at","source"}

One manifest per platform, because the android / windows / apple CI jobs run in
parallel and would otherwise race on a shared file. A request first reads the
manifest (cached 60 s at the edge) and streams the object with a real
Content-Length, ETag, Content-Disposition and byte-range support; the response
carries `x-fjolsky-source: r2` and `x-fjolsky-tag`. If there is no manifest, or
the object it names is gone, the request degrades to the GitHub redirect exactly
as before — so an empty bucket, a half-finished backfill, or a CI job whose R2
step failed never produces a dead link.

Why: the `*-ci` repos' GitHub Releases were the only copy of the installers, and
they are reachable only while those repos stay PUBLIC (private release assets
cannot be fetched anonymously) and only through third-party gh-proxy mirrors.
R2 puts the bytes on our own account, under our own hostname, with free egress.

Cost: R2 free tier is 10 GB-month storage, 1M class A and 10M class B
operations per month, egress free. Latest-only for 11 brands is ~2.5 GB; the CI
step keeps the two newest tags per app and prunes the rest, so the bucket stays
inside the free tier.

Filling it:

    scripts/backfill-r2.sh          one-off: upload every brand's CURRENT release + manifests
    (CI) "Publish to R2" step       every build: upload + manifest + prune (see ci-r2-upload-step.yml
                                    in this directory; secrets CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_R2_TOKEN / R2_BUCKET)

Testing without touching production: deploy the same source under another
script name, bind a throwaway custom hostname, and call it with `?brand=<brand-domain>` —
the Worker uses that instead of the hostname to pick the TABLE entry.

## Updating after a release

The asset URLs are baked into the Worker, so a new build needs a redeploy:

    export CF_TOKEN=$(security find-generic-password -s fjosky.cloudflare.fjolsky -w)
    ./create-cloudflare-app-downloads.sh

[2026-09-07] The two lines above are historical. Since 2026-08-04 the Worker
resolves the newest tag at request time, and since 2026-09-07 it reads the R2
manifests; nothing is baked per release. Run the deploy script only when
`workers/app-downloads.js` changes. It also runs a smoke test over all 11 brands.

The websites themselves need no change — they read the download links from
hydra (`GET /v1/public/pkg` with the room hash), which points at these
`dl.<brand>` URLs, so the indirection holds across releases.
