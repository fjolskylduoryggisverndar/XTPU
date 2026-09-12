// fjolsky-referral -- blocking-resistant referral landing + installer downloads
// on throwaway numeric domains, one domain pool per brand.
//
// Why this exists: the app's referral page hands out
// https://<official site>/r/<CODE>. Spreading the brand hostname in mainland
// chat groups is exactly how a brand domain gets reported and blocked, so the
// app ALSO shows https://<pool domain>/<CODE> -- a cheap numeric domain that is
// expected to be burned and replaced. hydra publishes which pool domain the
// app shows (RuleConfig.referral_short_domains, first active entry); every
// domain in TABLE stays bound to this Worker so links that were already shared
// keep working until that domain is actually blocked.
//
// Routes (pool hostname -> brand via TABLE):
//   /                              404 -- looks like an idle domain
//   /robots.txt                    disallow all
//   /<CODE>                        mini landing page: the code with a copy
//                                  button, one download button per platform;
//                                  language from ?lang= or Accept-Language
//                                  (zh-tw / zh-sg / en)
//   /<CODE>/android|windows|macos  the installer, streamed from the R2 bucket
//                                  (same layout fjolsky-downloads uses); 302
//                                  to the brand's dl.<domain> only if the
//                                  bucket has no manifest for that platform
//   /<CODE>/ios                    the landing page again (App Store only)
// <CODE> is the 6-char [0-9A-Z] affiliate code. It is NOT validated against
// hydra (there is no public lookup); an unknown code just yields a page whose
// code the newcomer will find rejected at registration.
//
// Every page view and download writes one row to the REFERRAL_CLICKS Analytics
// Engine dataset (brand, code, event, platform, country, host) -- the first
// rung of the "did my referral work" funnel. Nothing is written when the
// binding is absent (staging copies).
//
// Nothing on the page loads from, or links to, the official domain: no fonts,
// no images, no hrefs. The pool domain must keep working after the brand
// domain is blocked, and the page must not hand a censor the brand hostname.
// The logo is therefore a text wordmark.
//
// Same-origin staging: `?brand=<pool hostname>` overrides the hostname lookup
// so a copy deployed under another name can be exercised before the pool
// domains are bound. It only selects a TABLE entry, never a different bucket.

const BRANDS = {
  buddhajump: {
    name: "BuddhaJump",
    app: "buddhajump",                 // R2 key prefix, = fjolsky-downloads TABLE[].app
    dl: "https://dl.buddhajump.xyz",   // last-resort fallback when R2 has no manifest
    macApp: "BuddhaJumpWall",          // the notarized .dmg installs this app name
  },
};

// Pool hostname -> brand key. Rotation order and retirement dates live in hydra
// (RuleConfig.referral_short_domains); this table only says which brand a
// hostname belongs to. NEVER list an api.<digits>.xyz API-endpoint domain here.
const TABLE = {
  "109238784623.shop": "buddhajump",
  "238423904823.shop": "buddhajump",
  "542758625546.shop": "buddhajump",
  "109238784623.xyz": "buddhajump",
  "238423904823.xyz": "buddhajump",
  "542758625546.xyz": "buddhajump",
};

const PLATFORMS = ["android", "windows", "macos"];

// [copied from fjolsky-downloads] Content types for the R2 path.
const CONTENT_TYPE = {
  android: "application/vnd.android.package-archive",
  windows: "application/zip",
  macos: "application/x-apple-diskimage",
};

// The R2 manifest is tiny and changes only on release; cache it briefly at
// the edge so a burst of downloads is one R2 read, not thousands.
const MANIFEST_TTL = 60;

const CODE_RE = /^[0-9A-Za-z]{6}$/;

// Copy is the official site's own download-section wording (assets/locales),
// so the landing page never says anything the site does not. Taiwan copy
// deliberately never uses the word 「梯子」.
const I18N = {
  "zh-tw": {
    htmlLang: "zh-Hant",
    codeLabel: "你的推薦碼",
    copy: "複製推薦碼",
    copied: "已複製",
    howTo: "安裝並開啟 App 後，在註冊頁填入這個推薦碼。",
    title: "下載應用程式",
    description: "取得適用於您裝置的應用程式。請在下方選擇您的平台。",
    detected: "偵測到你正在使用 {platform}",
    downloadNow: "立即下載",
    directDescription: "不需要商店帳號：下載安裝檔後直接執行。不會自動更新，新版本請回到這裡下載。",
    comingSoon: "即將上架",
    macosNote: "首次使用：把 {macApp} 拖到「應用程式」並開啟 → 點「連線」→ 在「系統設定 → 一般 → 登入項目與延伸功能 → 網路延伸功能」允許「{macApp} Tunnel」系統延伸功能 → 允許加入 VPN 設定「{macApp}」。只需一次，之後一鍵連線。",
    platforms: { android: "Android", windows: "Windows", macos: "macOS", ios: "iOS" },
    files: { android: "APK 安裝檔", windows: "ZIP 免安裝", macos: "DMG 安裝檔", ios: "App Store" },
  },
  "zh-sg": {
    htmlLang: "zh-Hans",
    codeLabel: "你的推荐码",
    copy: "复制推荐码",
    copied: "已复制",
    howTo: "安装并打开 App 后，在注册页填入这个推荐码。",
    title: "下载应用",
    description: "获取适用于您设备的应用。请选择您的平台。",
    detected: "检测到你正在使用 {platform}",
    downloadNow: "立即下载",
    directDescription: "无需商店账号：下载安装包后直接运行。不会自动更新，新版本请回到这里下载。",
    comingSoon: "即将上架",
    macosNote: "首次使用：把 {macApp} 拖到“应用程序”并打开 → 点“连接” → 在“系统设置 → 通用 → 登录项与扩展 → 网络扩展”里允许“{macApp} Tunnel”系统扩展 → 允许添加 VPN 配置“{macApp}”。只需一次，以后一键连接。",
    platforms: { android: "Android", windows: "Windows", macos: "macOS", ios: "iOS" },
    files: { android: "APK 安装包", windows: "ZIP 免安装", macos: "DMG 安装包", ios: "App Store" },
  },
  en: {
    htmlLang: "en",
    codeLabel: "Your referral code",
    copy: "Copy code",
    copied: "Copied",
    howTo: "After installing and opening the app, enter this referral code on the sign-up page.",
    title: "Download App",
    description: "Get the app for your device. Choose your platform below.",
    detected: "You appear to be on {platform}",
    downloadNow: "Download Now",
    directDescription: "No store account needed: download the installer and run it. Updates are not automatic — come back here for new versions.",
    comingSoon: "Coming soon",
    macosNote: "First launch: drag {macApp} into Applications and open it → press Connect → allow the “{macApp} Tunnel” system extension in System Settings (General › Login Items & Extensions › Network Extensions) → allow the “{macApp}” VPN configuration. Done once; later connects are one click.",
    platforms: { android: "Android", windows: "Windows", macos: "macOS", ios: "iOS" },
    files: { android: "APK installer", windows: "ZIP, no installer", macos: "DMG installer", ios: "App Store" },
  },
};

function pickLang(url, request) {
  const q = (url.searchParams.get("lang") || "").toLowerCase();
  if (I18N[q]) return q;
  const header = (request.headers.get("accept-language") || "").toLowerCase();
  for (const part of header.split(",")) {
    const tag = part.split(";")[0].trim();
    if (!tag) continue;
    if (tag.startsWith("zh")) return /hant|tw|hk|mo/.test(tag) ? "zh-tw" : "zh-sg";
    if (tag.startsWith("en")) return "en";
  }
  return "en";
}

function detectPlatform(request) {
  const ua = request.headers.get("user-agent") || "";
  if (/iphone|ipad|ipod/i.test(ua)) return "ios";
  if (/android/i.test(ua)) return "android";
  if (/windows/i.test(ua)) return "windows";
  if (/macintosh|mac os x/i.test(ua)) return "macos";
  return null;
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function fill(template, vars) {
  return template.replace(/\{(\w+)\}/g, (_, k) => (k in vars ? vars[k] : `{${k}}`));
}

// One data point per page view / download. Analytics Engine has no schema:
// the blob order below IS the schema, keep it stable (see app-referral.md).
function track(env, request, fields) {
  try {
    if (!env || !env.REFERRAL_CLICKS) return;
    env.REFERRAL_CLICKS.writeDataPoint({
      indexes: [fields.code],
      blobs: [
        fields.brand,
        fields.code,
        fields.event,                       // "view" | "download"
        fields.platform || "",
        (request.cf && request.cf.country) || "",
        fields.host,
        fields.lang || "",
      ],
      doubles: [1],
    });
  } catch (_) {
    // analytics must never break a download
  }
}

// [copied from fjolsky-downloads] Read <app>/latest/<platform>.json from R2.
// Returns null when the bucket is not bound, the manifest is absent, or it
// does not parse -- every one of those means "fall back", never an error.
async function r2Manifest(env, brand, platform, request, ctx) {
  if (!env || !env.DOWNLOADS) return null;
  const cacheKey = new Request(new URL(`/__r2manifest/${brand.app}/${platform}`, request.url).toString());
  const cache = caches.default;
  const hit = await cache.match(cacheKey);
  if (hit) {
    try { return await hit.json(); } catch (_) { /* fall through to R2 */ }
  }
  let manifest = null;
  try {
    const obj = await env.DOWNLOADS.get(`${brand.app}/latest/${platform}.json`);
    if (obj) {
      const m = await obj.json();
      if (m && typeof m.tag === "string" && typeof m.key === "string") manifest = m;
    }
  } catch (_) {
    // R2 hiccup -- degrade to the dl.<brand> redirect
  }
  if (manifest) {
    ctx.waitUntil(cache.put(cacheKey, new Response(JSON.stringify(manifest), {
      headers: { "cache-control": `max-age=${MANIFEST_TTL}`, "content-type": "application/json" },
    })));
  }
  return manifest;
}

// [copied from fjolsky-downloads] Stream an object out of R2 with the headers
// a browser needs for a large download: real Content-Length, ETag, byte-range
// support (resumable downloads matter on a lossy link), and a filename.
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

// Palette = the official site's shared.css tokens (dark theme), inlined.
const CSS = `
:root{--bg:#05050a;--card:rgba(15,15,25,.8);--border:rgba(99,102,241,.2);--primary:#4f46e5;--primary-light:#a5b4fc;--accent:#22d3ee;--warm:#f472b6;--text:#e8eaf0;--muted:#9aa0b4}
*{box-sizing:border-box}html{color-scheme:dark}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,"PingFang TC","PingFang SC","Microsoft JhengHei","Microsoft YaHei",sans-serif}
main{max-width:34rem;margin:0 auto;padding:2.5rem 1.25rem 4rem}
.brand{font-weight:800;font-size:1.5rem;letter-spacing:.02em;background:linear-gradient(90deg,var(--primary-light),var(--accent));-webkit-background-clip:text;background-clip:text;color:transparent}
.card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:1.5rem;margin-top:1.25rem}
.label{color:var(--muted);font-size:.85rem;text-transform:uppercase;letter-spacing:.08em}
.code{font:700 2.4rem/1.2 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.18em;color:var(--warm);margin:.35rem 0 .75rem;user-select:all;-webkit-user-select:all}
button,.btn{display:inline-block;width:100%;text-align:center;border:0;border-radius:12px;padding:.85rem 1rem;font:600 1rem system-ui,sans-serif;color:#fff;background:var(--primary);text-decoration:none;cursor:pointer}
button:hover,.btn:hover{filter:brightness(1.1)}
.btn.secondary{background:transparent;border:1px solid var(--border);color:var(--text)}
.btn.disabled{opacity:.45;pointer-events:none}
.hint{color:var(--muted);font-size:.95rem;margin:.75rem 0 0}
h1{font-size:1.35rem;margin:0 0 .25rem}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:.75rem;margin-top:1rem}
.grid .btn{padding:.9rem .75rem}.grid small{display:block;font-weight:400;color:var(--primary-light);font-size:.8rem}
.detected{margin-top:1rem;padding:1rem;border-radius:12px;background:rgba(79,70,229,.15);border:1px solid var(--border)}
.detected p{margin:0 0 .6rem;color:var(--primary-light);font-size:.95rem}
.note{color:var(--muted);font-size:.85rem;line-height:1.55;margin-top:1rem}
@media (max-width:380px){.grid{grid-template-columns:1fr}.code{font-size:2rem}}
`;

function landingPage(brand, code, lang, detected, base) {
  const t = I18N[lang];
  const vars = { macApp: brand.macApp };
  const buttons = PLATFORMS.map((p) =>
    `<a class="btn secondary" href="${base}/${p}" data-platform="${p}">${esc(t.platforms[p])}<small>${esc(t.files[p])}</small></a>`
  ).join("") +
    `<span class="btn secondary disabled" aria-disabled="true">${esc(t.platforms.ios)}<small>${esc(t.files.ios)} · ${esc(t.comingSoon)}</small></span>`;
  const detectedBlock = detected && detected !== "ios"
    ? `<div class="detected"><p>${esc(fill(t.detected, { platform: t.platforms[detected] }))}</p>` +
      `<a class="btn" href="${base}/${detected}" data-platform="${detected}">${esc(t.downloadNow)} · ${esc(t.platforms[detected])}</a></div>`
    : detected === "ios"
      ? `<div class="detected"><p>${esc(fill(t.detected, { platform: t.platforms.ios }))} · ${esc(t.comingSoon)}</p></div>`
      : "";
  return `<!doctype html><html lang="${t.htmlLang}"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">` +
    `<title>${esc(brand.name)} · ${esc(code)}</title><style>${CSS}</style></head><body><main>` +
    `<div class="brand">${esc(brand.name)}</div>` +
    `<section class="card"><div class="label">${esc(t.codeLabel)}</div><div class="code" id="code">${esc(code)}</div>` +
    `<button type="button" id="copy" data-copied="${esc(t.copied)}">${esc(t.copy)}</button>` +
    `<p class="hint">${esc(t.howTo)}</p></section>` +
    `<section class="card"><h1>${esc(t.title)}</h1><p class="hint" style="margin:0">${esc(t.description)}</p>` +
    detectedBlock +
    `<div class="grid">${buttons}</div>` +
    `<p class="note">${esc(t.directDescription)}</p>` +
    `<p class="note">${esc(fill(t.macosNote, vars))}</p></section>` +
    `</main><script>(function(){var b=document.getElementById("copy"),c=document.getElementById("code");if(!b)return;` +
    `b.addEventListener("click",function(){var code=c.textContent.trim(),done=function(){var l=b.textContent;b.textContent=b.getAttribute("data-copied");setTimeout(function(){b.textContent=l},1500)};` +
    `if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(code).then(done,function(){fallback()})}else{fallback()}` +
    `function fallback(){var r=document.createRange();r.selectNodeContents(c);var s=window.getSelection();s.removeAllRanges();s.addRange(r);try{document.execCommand("copy");done()}catch(e){}}});})();</script></body></html>`;
}

function html(status, body, extra) {
  return new Response(body, {
    status,
    headers: Object.assign({ "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex" }, extra || {}),
  });
}

function text(status, body) {
  return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const host = (url.searchParams.get("brand") || url.hostname).toLowerCase();
    const brandKey = TABLE[host];
    const brand = brandKey && BRANDS[brandKey];
    const segments = url.pathname.split("/").filter(Boolean);

    if (!brand) return text(404, "Not found");
    if (request.method !== "GET" && request.method !== "HEAD") return text(405, "Method not allowed");

    if (segments.length === 0) return text(404, "Not found");
    if (segments.length === 1 && segments[0].toLowerCase() === "robots.txt") {
      return text(200, "User-agent: *\nDisallow: /\n");
    }

    const rawCode = segments[0];
    if (!CODE_RE.test(rawCode) || segments.length > 2) return text(404, "Not found");
    const code = rawCode.toUpperCase();
    const platform = (segments[1] || "").toLowerCase();
    const lang = pickLang(url, request);
    const base = `/${code}`;

    if (segments.length === 1 || platform === "ios") {
      const detected = detectPlatform(request);
      track(env, request, { brand: brandKey, code, event: "view", platform: platform || detected || "", host, lang });
      const body = landingPage(brand, code, lang, detected, base);
      return request.method === "HEAD" ? html(200, null) : html(200, body, { "content-language": I18N[lang].htmlLang });
    }

    if (!PLATFORMS.includes(platform)) return text(404, "Not found");

    track(env, request, { brand: brandKey, code, event: "download", platform, host, lang });
    const manifest = await r2Manifest(env, brand, platform, request, ctx);
    if (manifest) {
      const served = await r2Serve(env, manifest, platform, request);
      if (served) return served;
    }
    // Last resort: the brand's own dl.<domain> (official hostname, blockable).
    // Only reached when the bucket has no manifest / lost the object.
    return Response.redirect(`${brand.dl}/${platform}`, 302);
  },
};
