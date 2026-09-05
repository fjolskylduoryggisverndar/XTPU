# Node-side per-user byte metering (Job 4)

How a node counts bytes per account and ships them to hydra, what the
maintenance script installs to make that possible, and how to roll it back.
Server-side handling (dedup by `batch_seq`, `account_usage`, the 100 GB
monthly cap) lives in hydra.

## Pieces

| What | Where | From |
|---|---|---|
| sing-box built with `with_v2ray_api` | `/usr/bin/sing-box` (official package diverted to `/usr/bin/sing-box.distrib`) | GitHub Release `sing-box-<tag>-v2rayapi` of this repo, built by `.github/workflows/sing-box-v2rayapi.yml` |
| `sing-stats` gRPC client (QueryStats, reset) | `/usr/local/bin/sing-stats` | same release, source in `metering/sing-stats/` |
| `experimental.v2ray_api` block in the config | `/etc/sing-box/config.json` | spliced by Job 4; `stats.users` refreshed by the monitor on every user-list change |
| metering edition of the monitor | `/usr/local/bin/sing-monitor.sh` (previous copy kept as `.bak-<stamp>`) | `scripts/sing-monitor.sh` = hydra's v1.8.13 template verbatim (the `harvest` entry point is in both since 2026-09-05; only the file header differs) |
| pending increments + batch sequence | `/var/lib/sing-monitor/pending.json` | written only by the monitor, under its lock |
| off-switch | `/usr/local/sbin/node-metering-off.sh` | `scripts/node-metering-off.sh` |
| hold file | `/etc/sing-box/metering.off` | written by the off-switch; while present Job 4 does nothing on this node |
| installed release marker | `/var/lib/sing-monitor/metering.release` | Job 4 |

## Data path

1. sing-box counts bytes per **inbound user name** (`user>>>` counters).
   The anytls inbound users hydra sends carry `name` = account id, and
   `experimental.v2ray_api.stats.users` lists the same names (a user not in
   that list is not counted, hence the refresh in `update_config`).
2. Every 10 s the monitor runs `sing-stats -listen <v2ray_api.listen> -reset`,
   which returns `{"<uuid>":{"up":N,"down":N}}` for non-zero counters and
   zeroes them atomically, then folds the increments into `pending.json`.
3. The heartbeat `POST /v1/server/users` body gains `users` (the pending map)
   and `batch_seq`; all other fields are unchanged. A valid reply acks the batch:
   `users` cleared, `seq + 1`. A lost reply resends the same `seq` with more
   data accumulated; hydra drops `seq <= last_seq`, so the honest wording is
   "may under-count slightly, never double-counts".
4. Counters live in sing-box's memory. Every restart is preceded by a
   harvest: the monitor's own restart path, and Job 4 (which runs before
   Job 1's daily `apt-get install sing-box`, whose postinst restarts).

`seq` is seeded from the epoch second when `pending.json` is (re)created, so a
lost file never restarts below what hydra has already seen.

## Why a self-built binary and a diversion

The official apt package is built without `with_v2ray_api`; a config with an
`experimental.v2ray_api` block makes that binary fail `sing-box check`
permanently, and the 10 s monitor then never applies a user-list change again
("freeze trap"). So:

* the build-tag gate (`sing-box version` prints `with_v2ray_api`) is checked
  on the downloaded file **before** the diversion, and again on
  `/usr/bin/sing-box` **before** the block is spliced in;
* a config that has the block while the binary lacks the tag gets the block
  stripped (and the service restarted) on the next run, whatever caused it;
* `dpkg-divert --add --rename --divert /usr/bin/sing-box.distrib /usr/bin/sing-box`
  makes future package upgrades land in `.distrib`. That this holds through a
  real upgrade is inferred, not yet observed: verification steps are in
  `docs/HK001-merge-into-fleet.md`, last section.

The build uses upstream's own `release/DEFAULT_BUILD_TAGS_OTHERS` (their
CGO_ENABLED=0 linux tag set) plus `with_v2ray_api`. That is `DEFAULT_BUILD_TAGS`
minus `with_naive_outbound`, which needs the Chromium/cronet toolchain; no
node config uses a naive outbound.

Note for anyone touching `sing-stats`: the generated gRPC client stub in
`experimental/v2rayapi` is **not** usable as-is. The package's `init()`
renames the service to `v2ray.core.app.stats.command.StatsService` on the
server, while the generated client constants still say
`/experimental.v2rayapi.StatsService/...`, so `NewStatsServiceClient(...)`
gets `Unimplemented`. The client derives the method path from the
(init-patched) `StatsService_ServiceDesc.ServiceName` at run time instead.
Caught by a live test; CI repeats that test on every build.

## Rollout

`METERING_IPS` in `scripts/node-daily-maintenance.sh` is the canary list.
Order: AU001 (`168.222.243.5`) -> five nodes -> the fleet (`uname -m` on the
way: only `x86_64`/`aarch64` are served). A node picks the change up on its
next daily run (<= 24.5 h). Before the first canary day, publish the release:
run the workflow once with the default tag (`v1.14.0`, what the apt repo
currently ships) and confirm `METERING_RELEASE` in the script matches the
release tag.

What to look at on the canary after its first run:

    sudo journalctl -u update-sbox --no-pager | grep 'metering:'
    dpkg-divert --list /usr/bin/sing-box
    /usr/bin/sing-box version | grep Tags
    jq .experimental /etc/sing-box/config.json
    cat /var/lib/sing-monitor/pending.json
    ls -la /usr/local/bin/sing-monitor.sh*

## Rollback

* One node, now: `sudo /usr/local/sbin/node-metering-off.sh`. Restores the
  official binary, strips the block, restores the previous monitor, checks,
  restarts, and writes the hold file so Job 4 stays out. To re-enable later:
  `sudo rm /etc/sing-box/metering.off`.
* Fleet, via git: remove the IP(s) from `METERING_IPS` (or revert the commit).
  A metered node that is no longer listed runs the off-switch on its next
  daily run. It also gets the hold file, so re-adding it later needs the `rm`
  above as well.
* Wrong binary release: change `METERING_RELEASE`; Job 4 re-downloads,
  verifies, harvests, swaps and restarts.
