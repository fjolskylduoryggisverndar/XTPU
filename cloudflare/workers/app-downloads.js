// fjolsky-downloads -- one Worker serving every brand's app downloads.
//
// Why this exists: the published download links used to be bit.ly, whose own
// domain is blocked in mainland China, and the GitHub asset host it pointed at
// is blocked too. Serving the links from each brand's OWN domain means the
// hostname is ours (we can move it if it gets blocked) and the destination can
// be swapped without republishing anything.
//
// Route:  dl.<brand-domain>/<platform>   ->  302 to the release asset
// Platforms: android | windows  (ios/macos go to the App Store, not here)
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
};

const TAG_TTL = 600;

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
    const brandHost = url.hostname.replace(/^dl\./, "");
    const entry = TABLE[brandHost];
    const platform = url.pathname.replace(/^\/+|\/+$/g, "").toLowerCase();

    if (!entry) {
      return page(404, "Unknown site", `<p>No downloads are configured for <code>${brandHost}</code>.</p>`);
    }

    if (!platform || platform === "index.html") {
      const tag = (await latestTag(entry, request, ctx)) || entry.pin;
      const rows = Object.keys(ASSET)
        .map((p) => `<li><a href="/${p}">${p}</a> -- ${tag}</li>`)
        .join("");
      return page(200, `${entry.app} downloads`, `<ul>${rows}</ul>`);
    }

    if (!ASSET[platform]) {
      return page(404, "Unknown platform",
        `<p><code>${platform}</code> is not available. Try <a href="/android">android</a> or <a href="/windows">windows</a>.</p>`);
    }

    // ?backup=1 uses the old bit.ly link, kept as a censorship fallback.
    if (url.searchParams.get("backup") === "1") {
      const b = entry.backup[platform];
      if (b) return Response.redirect(b, 302);
      return page(404, "No backup link", `<p>There is no bit.ly backup for ${entry.app} ${platform}.</p>`);
    }

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
