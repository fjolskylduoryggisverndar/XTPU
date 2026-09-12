# fjolsky-referral — blocking-resistant referral links

**What it is.** A Worker on a pool of throwaway numeric domains, one pool per brand.
`https://<pool domain>/<CODE>` shows a mini landing page (the referral code with a copy
button, one download button per platform) and `https://<pool domain>/<CODE>/<platform>`
streams the installer from the same R2 bucket `fjolsky-downloads` uses. The BuddhaJump app
shows this link under its official-site referral link; the pool domain is what members paste
into chat groups, so a censorship block lands on a disposable name, not on the brand domain.

Source: `workers/app-referral.js`. Deploy: `create-cloudflare-app-referral.sh`
(`CF_TOKEN` from Keychain `fjosky.cloudflare.fjolsky`). Account `72b71eab…`, the same one
that holds the R2 bucket and `fjolsky-downloads`.

## Routes

| Path | Answer |
|---|---|
| `/` | 404 (an idle-looking domain) |
| `/robots.txt` | disallow all |
| `/<CODE>` | landing page; `?lang=zh-tw|zh-sg|en`, else Accept-Language |
| `/<CODE>/android` `/windows` `/macos` | installer from R2 (`<app>/latest/<platform>.json` manifest); 302 to `dl.<brand>` only when R2 has no manifest |
| `/<CODE>/ios` | landing page (App Store only, "coming soon") |

`<CODE>` = the 6-char affiliate code. Not validated against hydra (no public lookup).
`?brand=<pool hostname>` overrides the hostname lookup for staging copies.

The page loads nothing from and links nowhere on the official domain. Keep it that way.

## Which domain the app shows

hydra `RuleConfig.referral_short_domains` (v1.8.25), per room, in rotation order:

```json
"referral_short_domains": [
  {"domain": "109238784623.shop", "retire_at": "2027-09-07"},
  {"domain": "238423904823.shop", "retire_at": "2027-09-07"},
  {"domain": "542758625546.shop", "retire_at": "2027-09-07"},
  {"domain": "238423904823.xyz"},
  {"domain": "542758625546.xyz"},
  {"domain": "109238784623.xyz"}
]
```

`GET /v1/public/rule` returns only the entries still active on the server's UTC date and the
app shows the **first** one. `retire_at` is inclusive and exists because the `.shop` names are
not renewed (AUD 47/yr): purchase date + 360 days, five days before registration lapses.
Write the list with `POST /v1/manage/rule` — read the room's whole config back first, change
this field only, post the whole thing back (the row is an all-or-nothing replace).

## Rotation runbook

1. Decide a domain is blocked: mainland-side probe fails, or its clicks in the dataset drop to
   zero while the app is still showing it.
2. Remove (or move down) that entry in hydra's list. No app release. Leave it bound on the
   Worker — links already shared keep working for anyone who can still reach it.
3. Keep **two never-published spares** in the list at all times. Buy a replacement the same
   day: fresh random digits (never the same digits as an existing entry, never a date-like
   name — the `api.<date>.xyz` API-endpoint pool uses those), add the zone to this account,
   change NS, wait for `active`, add it to `TABLE` in the Worker and to `POOL_DOMAINS`,
   redeploy, then append it to hydra's list.
4. **Never** put an `api.<digits>.xyz` API-endpoint domain in this pool.

## Click / download counts

Dataset `fjolsky_referral_clicks` (Workers Analytics Engine, free tier). Blob order is the
schema — do not reorder:

```
blob1 brand   blob2 code   blob3 event ("view" | "download")   blob4 platform
blob5 country (request.cf.country)   blob6 host   blob7 lang    double1 = 1   index1 = code
```

Query with the SQL API (token needs Account Analytics: Read):

```sh
curl -s "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/analytics_engine/sql" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  --data "SELECT blob2 AS code, blob3 AS event, blob4 AS platform, SUM(_sample_interval) AS n
          FROM fjolsky_referral_clicks WHERE timestamp > NOW() - INTERVAL '7' DAY
          GROUP BY code, event, platform ORDER BY n DESC LIMIT 50"
```

This is the first rung of the referral funnel (click → download). Install → guest account →
bound referral code is the client/hydra attribution work, not this Worker.

**[2026-09-12] The official sites feed the same dataset.** `https://<site>/r/<CODE>` is now
redirected by each site's `_redirects` to `/?ref=<CODE>#download`; the homepage shows the code
with a copy button and appends `?ref=<CODE>` to its `dl.<brand>` download links, and the
`fjolsky-downloads` Worker (workers/app-downloads.js) writes a `download` row for every plain
GET that carries a valid code (HEAD and Range requests are not counted). Same blob order;
`blob6 host` is `dl.<brand>` for that channel versus a pool domain for the short links, and
`blob7 lang` there is the raw `Accept-Language` primary tag rather than the landing-page
language. There is no `view` row for the official site (it is a static Pages site).
