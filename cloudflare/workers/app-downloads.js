// fjolsky-downloads -- one Worker serving every brand's app downloads.
//
// Why this exists: the published download links used to be bit.ly, whose own
// domain is blocked in mainland China, and the GitHub asset host it pointed at
// is blocked too. Serving the links from each brand's OWN domain means the
// hostname is ours (we can move it if it gets blocked) and the destination can
// be swapped without republishing anything.
//
// Route:  dl.<brand-domain>/<platform>   ->  the release asset
// Platforms: android | windows | macos  (iOS is App Store only -- sideloading
//            an iOS app is not something we can offer from a web link)
//
// [2026-09-07] R2 becomes the primary source. Every request first looks for
// the asset in the DOWNLOADS R2 bucket (bound in wrangler / the deploy script)
// and streams it directly from this Worker under the brand's own hostname --
// no GitHub, no third-party gh-proxy mirror in the path any more. That is what
// lets the *-ci repos go private (private release assets cannot be fetched
// anonymously) and it removes the dependency on edgeone.gh-proxy.org staying
// alive and unblocked.
//
// The old GitHub path is kept VERBATIM below as the fallback: if the bucket has
// no manifest for a brand/platform yet (backfill not run, or CI predates the R2
// upload step) the request degrades to exactly what it did before. `?src=github`
// forces that path for debugging.
//
// R2 layout (written by scripts/backfill-r2.sh and by the CI upload step):
//   <app>/<tag>/<asset-filename>                 the bytes
//   <app>/latest/<platform>.json                 {"tag","key","size","sha256","published_at"}
// One manifest per platform (not per app) because the android / windows /
// apple CI jobs run in parallel and would otherwise race on a shared file.
//
// The version is resolved from the CI repo's latest GitHub release at request
// time, so a new build is published the moment CI tags it -- nothing here has to
// be edited per release. `pin` is the last-known-good tag and is used only when
// that lookup fails, so a GitHub outage degrades to a slightly stale download
// rather than a dead link.
//
// The destination is wrapped in a GitHub proxy mirror by default, because the
// raw asset host does not resolve for a large part of the audience. ?direct=1
// bypasses the mirror, which is the right choice from an unfiltered network.
// ?backup=1 falls back to the old bit.ly links where one still exists.
const TABLE = {
  "buddhajump.xyz": {
    app: "buddhajump", repo: "BuddhaJumpApp/buddhajump-ci", prefix: "buddhajump", pin: "v1.2.8+30",
    backup: { android: "https://bit.ly/3SayN1G", windows: "https://bit.ly/4c2qWKj" },
  },
  "kamevpn.xyz": {
    app: "kamevpn", repo: "fjolskylduoryggisverndar/kamevpn-ci", prefix: "kamevpn", pin: "v1.1.2+8",
    backup: { android: "https://bit.ly/45B621d", windows: "https://bit.ly/4wHPpNm" },
  },
  "aiglefree.xyz": {
    app: "aiglefree", repo: "BuddhaJumpApp/aiglefree-ci", prefix: "aiglefree", pin: "v1.1.2+10",
    backup: { android: null, windows: null },
  },
  "goddessv.xyz": {
    app: "goddessvpn", repo: "BuddhaJumpApp/goddessvpn-ci", prefix: "goddessvpn", pin: "v1.1.2+11",
    backup: { android: null, windows: "https://bit.ly/3UaOuGE" },
  },
  "libertygatevpn.xyz": {
    app: "libertygate", repo: "BuddhaJumpApp/libertygate-ci", prefix: "libertygate", pin: "v1.1.2+10",
    backup: { android: null, windows: "https://bit.ly/4wfHOoo" },
  },
  "maschvpn.xyz": {
    app: "maschvpn", repo: "BuddhaJumpApp/maschvpn-ci", prefix: "maschvpn", pin: "v1.1.2+10",
    backup: { android: null, windows: null },
  },
  "maskaura.xyz": {
    app: "maskaura", repo: "BuddhaJumpApp/maskaura-ci", prefix: "maskaura", pin: "v1.1.2+11",
    backup: { android: null, windows: "https://bit.ly/4fC6aU3" },
  },
  "ninjashield.xyz": {
    app: "ninjashield", repo: "BuddhaJumpApp/ninjashield-ci", prefix: "ninjashield", pin: "v1.1.2+10",
    backup: { android: null, windows: null },
  },
  "openbridgeapp.xyz": {
    app: "openbridge", repo: "BuddhaJumpApp/openbridge-ci", prefix: "openbridge", pin: "v1.1.2+11",
    backup: { android: null, windows: null },
  },
  // The 00000/88888 CI jobs name their assets vpn00000-*/vpn88888-*, not 00000vpn-*.
  "00000vpn.com": {
    app: "00000vpn", repo: "fjolskylduoryggisverndar/00000vpn-ci", prefix: "vpn00000", pin: "v3.2.2+8",
    backup: { android: null, windows: null },
  },
  "88888vpn.com": {
    app: "88888vpn", repo: "fjolskylduoryggisverndar/88888vpn-ci", prefix: "vpn88888", pin: "v3.2.2+8",
    backup: { android: null, windows: null },
  },
};

// Mirrors are tried in order; the first is the default redirect target.
const MIRRORS = [
  (u) => `https://edgeone.gh-proxy.org/${u}`,
  (u) => `https://gh-proxy.com/${u}`,
];

const ASSET = {
  android: (prefix, tag) => `${prefix}-android-universal-${tag}.apk`,
  windows: (prefix, tag) => `${prefix}-windows-amd64-${tag}.zip`,
  // [2026-09-01] macOS joins the direct downloads. The header above used to say
  // macOS "goes to the App Store, not here", which left Mac users with nothing:
  // the only macOS artifact the build produced was an App Store SUBMISSION .pkg
  // (signed "3rd Party Mac Developer Installer") that a downloader cannot
  // install. The CI now also builds a Developer ID-signed, notarized, stapled
  // .dmg, which is what this serves. entry.backup has no macos key, so the
  // ?backup=1 path simply falls through to the normal redirect.
  macos: (prefix, tag) => `${prefix}-macos-${tag}.dmg`,
};

// [2026-09-07] Content types for the R2 path. GitHub set these for us before.
const CONTENT_TYPE = {
  android: "application/vnd.android.package-archive",
  windows: "application/zip",
  macos: "application/x-apple-diskimage",
};

const TAG_TTL = 600;
// [2026-09-07] The R2 manifest is tiny and changes only on release; cache it
// briefly at the edge so a download burst is one R2 read, not thousands.
const MANIFEST_TTL = 60;

// Resolve the newest release tag by reading the redirect GitHub serves for
// /releases/latest. The result is cached at the edge so a burst of downloads
// costs one lookup, and any failure returns null so the caller can fall back to
// the pinned tag rather than serving a broken link.
async function latestTag(entry, request, ctx) {
  const key = new Request(new URL(`/__tag/${encodeURIComponent(entry.repo)}`, request.url).toString());
  const cache = caches.default;
  const hit = await cache.match(key);
  if (hit) return (await hit.text()) || null;

  let tag = null;
  try {
    const r = await fetch(`https://github.com/${entry.repo}/releases/latest`, {
      redirect: "manual",
      signal: AbortSignal.timeout(5000),
      headers: { "user-agent": "fjolsky-downloads" },
    });
    const m = (r.headers.get("location") || "").match(/\/releases\/tag\/(.+)$/);
    if (m) tag = decodeURIComponent(m[1]);
  } catch (_) {
    // network error or timeout -- fall through to the pin
  }
  if (tag) {
    ctx.waitUntil(cache.put(key, new Response(tag, {
      headers: { "cache-control": `max-age=${TAG_TTL}`, "content-type": "text/plain" },
    })));
  }
  return tag;
}

// [2026-09-07] Read <app>/latest/<platform>.json from R2. Returns null when the
// bucket is not bound, the manifest is absent, or it does not parse -- every
// one of those means "use the GitHub path", never an error to the user.
async function r2Manifest(env, entry, platform, request, ctx) {
  if (!env || !env.DOWNLOADS) return null;
  const cacheKey = new Request(new URL(`/__r2manifest/${entry.app}/${platform}`, request.url).toString());
  const cache = caches.default;
  const hit = await cache.match(cacheKey);
  if (hit) {
    try { return await hit.json(); } catch (_) { /* fall through to R2 */ }
  }
  let manifest = null;
  try {
    const obj = await env.DOWNLOADS.get(`${entry.app}/latest/${platform}.json`);
    if (obj) {
      const m = await obj.json();
      if (m && typeof m.tag === "string" && typeof m.key === "string") manifest = m;
    }
  } catch (_) {
    // R2 hiccup -- degrade to GitHub
  }
  if (manifest) {
    ctx.waitUntil(cache.put(cacheKey, new Response(JSON.stringify(manifest), {
      headers: { "cache-control": `max-age=${MANIFEST_TTL}`, "content-type": "application/json" },
    })));
  }
  return manifest;
}

// [2026-09-07] Stream an object out of R2 with the headers a browser needs for
// a large download: real Content-Length, ETag, byte-range support (resumable
// downloads matter on a lossy link), and a filename via Content-Disposition.
async function r2Serve(env, manifest, platform, request) {
  const filename = manifest.key.split("/").pop();
  const common = {
    "content-type": manifest.content_type || CONTENT_TYPE[platform] || "application/octet-stream",
    "content-disposition": `attachment; filename="${filename}"`,
    "accept-ranges": "bytes",
    "cache-control": "public, max-age=3600",
    "x-fjolsky-source": "r2",
    "x-fjolsky-tag": manifest.tag,
  };
  if (request.method === "HEAD") {
    const head = await env.DOWNLOADS.head(manifest.key);
    if (!head) return null;
    const h = new Headers(common);
    head.writeHttpMetadata(h);
    h.set("content-length", String(head.size));
    h.set("etag", head.httpEtag);
    return new Response(null, { status: 200, headers: h });
  }
  const obj = await env.DOWNLOADS.get(manifest.key, { range: request.headers, onlyIf: request.headers });
  if (!obj) return null;
  const h = new Headers(common);
  obj.writeHttpMetadata(h);
  h.set("etag", obj.httpEtag);
  // A conditional request that matched returns an R2Object without a body.
  if (!("body" in obj) || obj.body === undefined) {
    return new Response(null, { status: 304, headers: h });
  }
  if (obj.range) {
    const { offset, length } = obj.range;
    const end = offset + length - 1;
    h.set("content-range", `bytes ${offset}-${end}/${obj.size}`);
    h.set("content-length", String(length));
    return new Response(obj.body, { status: 206, headers: h });
  }
  h.set("content-length", String(obj.size));
  return new Response(obj.body, { status: 200, headers: h });
}

function page(status, title, body) {
  return new Response(
    `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">` +
    `<title>${title}</title>` +
    `<style>body{font:16px/1.6 system-ui,sans-serif;max-width:38rem;margin:12vh auto;padding:0 1.5rem;` +
    `background:#0b0d13;color:#e8eaf0}a{color:#7aa2ff}code{background:#1a1e2b;padding:.15em .4em;border-radius:4px}</style>` +
    `<h1>${title}</h1>${body}`,
    { status, headers: { "content-type": "text/html; charset=utf-8" } }
  );
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    // dl.buddhajump.xyz -> buddhajump.xyz
    // [2026-09-07] `?brand=<brand-domain>` overrides the hostname lookup so a
    // staging copy of this Worker on a workers.dev hostname can be exercised
    // end-to-end before it is deployed under the dl.<brand> domains. Harmless
    // in production: it only selects a TABLE entry, never a different backend.
    const brandHost = url.searchParams.get("brand") || url.hostname.replace(/^dl\./, "");
    const entry = TABLE[brandHost];
    const platform = url.pathname.replace(/^\/+|\/+$/g, "").toLowerCase();

    if (!entry) {
      return page(404, "Unknown site", `<p>No downloads are configured for <code>${brandHost}</code>.</p>`);
    }

    if (!platform || platform === "index.html") {
      // [2026-09-07] The index shows, per platform, which tag would be served
      // and from where, so an operator can see at a glance whether R2 is live.
      const rows = [];
      for (const p of Object.keys(ASSET)) {
        const m = await r2Manifest(env, entry, p, request, ctx);
        if (m) { rows.push(`<li><a href="/${p}">${p}</a> -- ${m.tag} <small>(r2)</small></li>`); continue; }
        const tag = (await latestTag(entry, request, ctx)) || entry.pin;
        rows.push(`<li><a href="/${p}">${p}</a> -- ${tag} <small>(github)</small></li>`);
      }
      return page(200, `${entry.app} downloads`, `<ul>${rows.join("")}</ul>`);
    }

    if (!ASSET[platform]) {
      return page(404, "Unknown platform",
        `<p><code>${platform}</code> is not available. Try <a href="/android">android</a>, <a href="/windows">windows</a> or <a href="/macos">macos</a>.</p>`);
    }

    // ?backup=1 uses the old bit.ly link, kept as a censorship fallback.
    if (url.searchParams.get("backup") === "1") {
      const b = entry.backup[platform];
      if (b) return Response.redirect(b, 302);
      return page(404, "No backup link", `<p>There is no bit.ly backup for ${entry.app} ${platform}.</p>`);
    }

    // [2026-09-07] Primary path: serve from R2 under our own hostname.
    if (url.searchParams.get("src") !== "github") {
      const manifest = await r2Manifest(env, entry, platform, request, ctx);
      if (manifest) {
        const served = await r2Serve(env, manifest, platform, request);
        if (served) return served;
        // Manifest points at a key that is gone -- fall through to GitHub rather
        // than 404, and let the operator notice via the index page.
      }
    }

    // Legacy path, unchanged: resolve the tag on GitHub and 302 via a mirror.
    const tag = (await latestTag(entry, request, ctx)) || entry.pin;
    const target = `https://github.com/${entry.repo}/releases/download/` +
      `${encodeURIComponent(tag)}/${encodeURIComponent(ASSET[platform](entry.prefix, tag))}`;

    // ?direct=1 skips the mirror; ?mirror=N picks a specific one.
    const direct = url.searchParams.get("direct") === "1";
    const idx = Number(url.searchParams.get("mirror") || 0);
    const dest = direct ? target : (MIRRORS[idx] || MIRRORS[0])(target);

    return Response.redirect(dest, 302);
  },
};
