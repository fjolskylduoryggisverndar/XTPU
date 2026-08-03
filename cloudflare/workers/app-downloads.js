// fjolsky-downloads — one Worker serving every brand's app downloads.
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
// The destination is wrapped in a GitHub proxy mirror by default, because the
// raw asset host does not resolve for a large part of the audience. ?direct=1
// bypasses the mirror, which is the right choice from an unfiltered network.
const TABLE = {
  "buddhajump.xyz": {
    "app": "buddhajump",
    "version": "1.2.6+28",
    "android": "https://github.com/BuddhaJumpApp/buddhajump-ci/releases/download/v1.2.6%2B28/buddhajump-android-universal-v1.2.6%2B28.apk",
    "windows": "https://github.com/BuddhaJumpApp/buddhajump-ci/releases/download/v1.2.6%2B28/buddhajump-windows-amd64-v1.2.6%2B28.zip",
    "backup": {
      "android": "https://bit.ly/3SayN1G",
      "windows": "https://bit.ly/4c2qWKj"
    }
  },
  "kamevpn.xyz": {
    "app": "kamevpn",
    "version": "1.1.1+7",
    "android": "https://github.com/fjolskylduoryggisverndar/kamevpn-ci/releases/download/v1.1.1%2B7/kamevpn-android-universal-v1.1.1%2B7.apk",
    "windows": "https://github.com/fjolskylduoryggisverndar/kamevpn-ci/releases/download/v1.1.1%2B7/kamevpn-windows-amd64-v1.1.1%2B7.zip",
    "backup": {
      "android": "https://bit.ly/45B621d",
      "windows": "https://bit.ly/4wHPpNm"
    }
  },
  "aiglefree.xyz": {
    "app": "aiglefree",
    "version": "1.1.1+9",
    "android": "https://github.com/BuddhaJumpApp/aiglefree-ci/releases/download/v1.1.1%2B9/aiglefree-android-universal-v1.1.1%2B9.apk",
    "windows": "https://github.com/BuddhaJumpApp/aiglefree-ci/releases/download/v1.1.1%2B9/aiglefree-windows-amd64-v1.1.1%2B9.zip",
    "backup": {
      "android": null,
      "windows": null
    }
  },
  "goddessv.xyz": {
    "app": "goddessvpn",
    "version": "1.1.1+10",
    "android": "https://github.com/BuddhaJumpApp/goddessvpn-ci/releases/download/v1.1.1%2B10/goddessvpn-android-universal-v1.1.1%2B10.apk",
    "windows": "https://github.com/BuddhaJumpApp/goddessvpn-ci/releases/download/v1.1.1%2B10/goddessvpn-windows-amd64-v1.1.1%2B10.zip",
    "backup": {
      "android": null,
      "windows": "https://bit.ly/3UaOuGE"
    }
  },
  "libertygatevpn.xyz": {
    "app": "libertygate",
    "version": "1.1.1+9",
    "android": "https://github.com/BuddhaJumpApp/libertygate-ci/releases/download/v1.1.1%2B9/libertygate-android-universal-v1.1.1%2B9.apk",
    "windows": "https://github.com/BuddhaJumpApp/libertygate-ci/releases/download/v1.1.1%2B9/libertygate-windows-amd64-v1.1.1%2B9.zip",
    "backup": {
      "android": null,
      "windows": "https://bit.ly/4wfHOoo"
    }
  },
  "maschvpn.xyz": {
    "app": "maschvpn",
    "version": "1.1.1+9",
    "android": "https://github.com/BuddhaJumpApp/maschvpn-ci/releases/download/v1.1.1%2B9/maschvpn-android-universal-v1.1.1%2B9.apk",
    "windows": "https://github.com/BuddhaJumpApp/maschvpn-ci/releases/download/v1.1.1%2B9/maschvpn-windows-amd64-v1.1.1%2B9.zip",
    "backup": {
      "android": null,
      "windows": null
    }
  },
  "maskaura.xyz": {
    "app": "maskaura",
    "version": "1.1.1+10",
    "android": "https://github.com/BuddhaJumpApp/maskaura-ci/releases/download/v1.1.1%2B10/maskaura-android-universal-v1.1.1%2B10.apk",
    "windows": "https://github.com/BuddhaJumpApp/maskaura-ci/releases/download/v1.1.1%2B10/maskaura-windows-amd64-v1.1.1%2B10.zip",
    "backup": {
      "android": null,
      "windows": "https://bit.ly/4fC6aU3"
    }
  },
  "ninjashield.xyz": {
    "app": "ninjashield",
    "version": "1.1.1+9",
    "android": "https://github.com/BuddhaJumpApp/ninjashield-ci/releases/download/v1.1.1%2B9/ninjashield-android-universal-v1.1.1%2B9.apk",
    "windows": "https://github.com/BuddhaJumpApp/ninjashield-ci/releases/download/v1.1.1%2B9/ninjashield-windows-amd64-v1.1.1%2B9.zip",
    "backup": {
      "android": null,
      "windows": null
    }
  },
  "openbridgeapp.xyz": {
    "app": "openbridge",
    "version": "1.1.1+10",
    "android": "https://github.com/BuddhaJumpApp/openbridge-ci/releases/download/v1.1.1%2B10/openbridge-android-universal-v1.1.1%2B10.apk",
    "windows": "https://github.com/BuddhaJumpApp/openbridge-ci/releases/download/v1.1.1%2B10/openbridge-windows-amd64-v1.1.1%2B10.zip",
    "backup": {
      "android": null,
      "windows": null
    }
  },
  "00000vpn.com": {
    "app": "00000vpn",
    "version": "3.2.1+7",
    "android": "https://github.com/fjolskylduoryggisverndar/00000vpn-ci/releases/download/v3.2.1%2B7/vpn00000-android-universal-v3.2.1%2B7.apk",
    "windows": "https://github.com/fjolskylduoryggisverndar/00000vpn-ci/releases/download/v3.2.1%2B7/vpn00000-windows-amd64-v3.2.1%2B7.zip",
    "backup": {
      "android": null,
      "windows": null
    }
  },
  "88888vpn.com": {
    "app": "88888vpn",
    "version": "3.2.1+7",
    "android": "https://github.com/fjolskylduoryggisverndar/88888vpn-ci/releases/download/v3.2.1%2B7/vpn88888-android-universal-v3.2.1%2B7.apk",
    "windows": "https://github.com/fjolskylduoryggisverndar/88888vpn-ci/releases/download/v3.2.1%2B7/vpn88888-windows-amd64-v3.2.1%2B7.zip",
    "backup": {
      "android": null,
      "windows": null
    }
  }
};

// Mirrors are tried in order; the first is the default redirect target.
const MIRRORS = [
  (u) => `https://edgeone.gh-proxy.org/${u}`,
  (u) => `https://gh-proxy.com/${u}`,
];

function page(status, title, body) {
  return new Response(
    `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">` +
    `<title>${title}</title>` +
    `<style>body{font:16px/1.6 system-ui,sans-serif;max-width:38rem;margin:12vh auto;padding:0 1.5rem;` +
    `background:#0b0d13;color:#e8eaf0}a{color:#7aa2ff}code{background:#1a1e2b;padding:.15em .4em;border-radius:4px}</style>` +
    `<h1>${title}</h1>${body}`,
    { status, headers: { 'content-type': 'text/html; charset=utf-8' } }
  );
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    // dl.buddhajump.xyz -> buddhajump.xyz
    const brandHost = url.hostname.replace(/^dl\./, '');
    const entry = TABLE[brandHost];
    const platform = url.pathname.replace(/^\/+|\/+$/g, '').toLowerCase();

    if (!entry) {
      return page(404, 'Unknown site', `<p>No downloads are configured for <code>${brandHost}</code>.</p>`);
    }

    if (!platform || platform === 'index.html') {
      const rows = ['android', 'windows']
        .map((p) => `<li><a href="/${p}">${p}</a> — v${entry.version}</li>`)
        .join('');
      return page(200, `${entry.app} downloads`, `<ul>${rows}</ul>`);
    }

    const target = entry[platform];
    if (!target) {
      return page(404, 'Unknown platform', `<p><code>${platform}</code> is not available. Try <a href="/android">android</a> or <a href="/windows">windows</a>.</p>`);
    }

    // ?direct=1 skips the mirror; ?mirror=N picks a specific one.
    const direct = url.searchParams.get('direct') === '1';
    const idx = Number(url.searchParams.get('mirror') || 0);
    const dest = direct ? target : (MIRRORS[idx] || MIRRORS[0])(target);

    return Response.redirect(dest, 302);
  },
};
