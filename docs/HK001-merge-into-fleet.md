# Runbook: merge HK001 into the fleet-wide per-IP shaping

One-off manual operation on HK001 (`191.222.218.103`). Nothing here is
automated on purpose: it retires a node-local systemd unit and rebuilds a live
tc tree, and the order of the steps is what keeps HK001 shaped throughout.

Outcome: HK001 stops running the tiered daily-volume throttle
(`node-tierlimit`, 8/2 mbit + 2 GiB / 6 GiB netem tiers) and gets the same
flat 36/12 mbit per-client-IP shaping as every other node (Job 2 of
`scripts/node-daily-maintenance.sh`). Fleet values are unchanged (decision:
keep 36/12). Nothing is deleted; every retired piece stays on disk for the
rollback at the end.

## Prerequisites (do NOT start without them)

1. **Hong Kong guardrails are in place on hydra first.** Once HK001 is on flat
   shaping it has no daily volume cap of its own any more, so the server-side
   guardrails must already be deployed: `HK_COHORT_PERCENT` lowered to 25 and
   `weekly_cap` (55 GB) kept. If that hydra release is not live, stop here.
2. **XTPU commit "Drop HK001 from SPECIAL_IPS" is on `main`** (the line in
   `scripts/node-daily-maintenance.sh` reads `SPECIAL_IPS=""`, old value kept as
   a comment tagged `[v3 2026-09-05]`). The nodes fetch the script from
   `raw.githubusercontent.com/.../main/...` at run time, so "pushed to main" is
   what matters, not "committed locally".

   Order matters: push first, then touch the node. If the node steps were done
   first and HK001 rebooted before the push, the probe in `apply_shaping()`
   would no longer see a tiered node, but the (old) IP list would still skip it
   -> HK001 would run with no shaping at all until the next daily run after the
   push.

## Access

    ssh -i node_credentials/fjolsky_node_admin_ed25519 dev@191.222.218.103

(break-glass key; valid on HK001 -- from memory, verify on connect.)

## Steps

### 0. Look before touching (state is from memory, not verified this round)

    sudo systemctl status node-tierlimit.service node-tier-ctl.timer --no-pager
    sudo systemctl list-timers --all | grep -E 'tier|update-sbox'
    ls -la /usr/local/sbin/node-tierlimit-*.sh /usr/local/sbin/node-ratelimit-off.sh 2>/dev/null
    sudo tc qdisc show dev eth0 | head; sudo tc class show dev eth0 | grep -cE '1:610|1:620'
    sudo nft list table ip fjolsky_tiers >/dev/null 2>&1 && echo "tiers table present"

Note down which units exist and are active. If the unit names differ from the
ones below, use the real names -- do not guess.

### 1. Stop the tiered controller and keep it from coming back on boot

    sudo systemctl disable --now node-tierlimit.service node-tier-ctl.timer

This stops the 60 s tick and prevents the tier tree from being rebuilt at boot.

### 2. Tear the tiered tree down

    sudo /usr/local/sbin/node-tierlimit-off.sh

Removes the eth0 root/ingress qdiscs, `ifb0`, and the nft table
`fjolsky_tiers`. **From this moment until step 4 completes, HK001 is
completely un-shaped.** Do steps 3 and 4 immediately.

### 3. Retire the apply script without deleting it

    sudo chmod -x /usr/local/sbin/node-tierlimit-apply.sh

`apply_shaping()` in the maintenance script treats "apply script is
executable OR nft table exists" as "tiered node, leave it alone". Removing the
execute bit (file kept) plus the table removal in step 2 is what lets Job 2 take
over. Nothing else in the maintenance script needs to know about HK001.

### 4. Run the maintenance script the way production runs it

    curl -fsSL https://raw.githubusercontent.com/fjolskylduoryggisverndar/XTPU/main/scripts/node-daily-maintenance.sh | sudo bash

Yes, `bash`, even though the script says `#!/bin/dash` -- that is the exact
invocation in the `update-sbox` unit, and past incidents came from testing
under one shell and running under the other. Job 2 builds the 256-bucket
36/12 tree with `LINE=1000mbit` (the old HK001 aggregate cap of 250 mbit goes
away; CPU protection now comes from hydra taking a node out of rotation above
80 % throughput).

Expect log lines like `shaping: applied per-IP 36mbit/12mbit on eth0
(egress=ok singbox=active)`. If you see `health gate FAILED ... reverting to
un-shaped` stop and investigate: the node is un-shaped at that point.

### 5. Verify (all of these, not some)

    sudo tc class show dev eth0 | grep -c 'class htb'          # expect 258 (1:1 + 1:9999 + 256 buckets)
    sudo tc class show dev eth0 | grep -E '1:610|1:620'         # expect no output (tier classes gone)
    sudo tc qdisc show dev eth0 | grep -c netem                 # expect 0
    sudo nft list table ip fjolsky_tiers                        # expect "No such file or directory" / does not exist
    sudo tc class show dev eth0 | grep -m1 'ceil'               # expect ... ceil 36Mbit burst 48Kb ... (unit Mbit, NOT Mbps)
    sudo tc class show dev ifb0 | grep -m1 'ceil'               # expect ... ceil 12Mbit burst 18Kb ...
    systemctl is-active sing-box                                # expect active

Then, from your laptop, open a **new** SSH session to HK001 and confirm it
connects (shaping only touches tcp port 443; SSH must be unaffected).

Optional, from a client on the HK node: a single download should now top out
around 36 mbit instead of 8.

### 6. If the fleet value were ever changed (not this round)

The decision this round is to keep 36/12, so nothing to do. For the record: the
script has **no** runtime assertion that the 256 buckets' guaranteed rates stay
under `LINE` (the "Aggregate stays safe" text is a comment), and the health
gate checks structure, not values -- a typo like `36mbps` would be applied
silently 8x too wide. Any future value change must be run on AU001 first via the
same `curl | sudo bash` and the `ceil` line eyeballed for unit and value.

## Verification item for the metering canary (spec [7])

Job 4 (metering) installs a self-built `sing-box` at `/usr/bin/sing-box` behind
`dpkg-divert`; Job 1 keeps running `apt-get install -y sing-box` daily. The
expectation is that a new upstream package lands in `/usr/bin/sing-box.distrib`
and our binary is untouched. This is inferred from dpkg semantics and has to be
observed once on the canary (AU001, `168.222.243.5`) after its first metered
day:

    dpkg-divert --list /usr/bin/sing-box                        # expect: local diversion of /usr/bin/sing-box to /usr/bin/sing-box.distrib
    /usr/bin/sing-box version | grep -c with_v2ray_api          # expect 1 (ours)
    /usr/bin/sing-box.distrib version | grep -c with_v2ray_api  # expect 0 (official)
    dpkg -s sing-box | grep '^Version'                          # note it
    sudo apt-get -qq install -o Dpkg::Options::="--force-confold" -y sing-box   # the exact Job 1 line
    /usr/bin/sing-box version | grep -c with_v2ray_api          # still 1
    ls -la /usr/bin/sing-box /usr/bin/sing-box.distrib
    systemctl is-active sing-box; sudo sing-box check -c /etc/sing-box/config.json && echo check-ok

To force a real package upgrade through the diversion (rather than a no-op
reinstall), run the same lines on a day the upstream repo has a newer version
than `dpkg -s` reported, or `apt-get install --reinstall -y sing-box` and
confirm the reinstalled file is `.distrib`, not `/usr/bin/sing-box`.

If the diversion did NOT hold (`/usr/bin/sing-box` lost the tag), run
`sudo /usr/local/sbin/node-metering-off.sh` right away -- the official binary
with the `experimental.v2ray_api` block still in the config is the freeze trap
(`sing-box check` fails, the 10 s monitor stops applying user changes).

## Rollback

Flat shaping, whole fleet: `git revert` the SPECIAL_IPS commit on `main`
(converges within one daily run, <= 24.5 h), or per node
`sudo /usr/local/sbin/node-ratelimit-off.sh` (un-shaped until the next daily
run).

HK001 back to tiered:

    sudo /usr/local/sbin/node-ratelimit-off.sh
    sudo chmod +x /usr/local/sbin/node-tierlimit-apply.sh
    sudo systemctl enable --now node-tierlimit.service node-tier-ctl.timer
    sudo /usr/local/sbin/node-tierlimit-apply.sh

After that the maintenance script sees an executable apply script / the nft
table again and leaves HK001 alone regardless of `SPECIAL_IPS`.
