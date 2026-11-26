# UrNetwork multi-provider fleet (urnetwork-3.23-fix)

Run **multiple independent provider identities** on one host, each with its own
container and state volume. One script, one config file.

Based on [urnetwork-3.23-fix](https://github.com/full-bars/urnetwork-3.23-fix).

---

## Read this first: what actually drives bandwidth

This setup gets the providers **running**. It does not, on its own, make them
**earn a lot**, and it is worth knowing why so you tune the right knob.

A provider's billable volume comes from the traffic the network routes through
it. Two things limit that here:

**1. Proxies are the lever — and there are none by default.**

With no proxy list, each container runs a single `direct` identity: one machine,
one public IP, competing as one peer. `urnet-tools proxy summary` on a fresh
fleet reports `Total proxies: 0`. Adding proxies is what multiplies the number of
identities and the volume routed to you.

**Preferred: a live feed.** Set `PROXY_URL` and the provider fetches, dedupes,
grades and reaps by itself — no cron, no scripts. [Proxifly](https://github.com/proxifly/free-proxy-list)
republishes and validates every 5 minutes:

```env
PROXY_URL=https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt
PROXY_URL_REFRESH=1h
PROXY_URL_MAX=150
```

Measured on one node against that feed: 5709 listed → 5684 dialed → 83
reachable → **25 admitted** (`A=25 B=8 D=4 F=46`). The funnel is the point:
free proxies are mostly dead, and only graded ones ever carry traffic. Anything
that fails is rejected, and dead entries are pruned on a 6h cadence, so a
decaying feed degrades toward `direct` instead of breaking the node.

Use SOCKS5 — the provider speaks it natively. If you are on a metered
connection, note the daily job downloads the whole list (~5.7k lines) per
node per refresh.

### Keeping one node on your own IP

Nodes `1..URNETWORK_DIRECT_NODES` get **no proxy source at all**, so their
traffic leaves through this host's own connection. That is the node the network
sees as a real residential exit, which is what it scores best. Everything above
`N` takes the feed.

```env
URNETWORK_DIRECT_NODES=1    # urfix-1 residential, urfix-2..6 proxied
```

Pin the node that already has earnings history — switching a node from proxied
to residential keeps its `client_id`, but starting fresh loses the warm-up.

A subtlety worth knowing: unsetting `PROXY_URL` is **not** enough to make a node
residential. Proxies persist in the state volume, so the node keeps running
`mode=mixed` until they are cleared. The script handles this — after a
residential node is up it runs `urnet-tools proxy clear --force`, and logs
`cleared persisted proxies (now direct-only)`. Without that step the node still
egresses through proxies despite having no feed configured.

**Or a static file.** Put entries in `proxies.txt` (shipped, header-only until
you fill it) and point `.env` at it:

```env
PROXY_FILE=/home/solis/Documentos/Code/urn/proxies.txt
```

The script mounts it read-only into every container and skips it entirely
while the file has no real entries, so an untouched `proxies.txt` changes
nothing. Add entries or refresh without a restart:

```sh
docker exec urfix-1 urnet-tools proxy add /app/proxy.txt
docker exec urfix-1 urnet-tools proxy refresh   # --force within 8-12h of a restart
```

**2. All containers share one public IP.**

Docker `bridge` networking NATs every container through the host's address, so
on the network all your instances look like the same origin. Separate state
volumes give each container its own `client_id`, and the dashboard will list
them separately, but they are not separate *network* peers.

An earlier version of this repo attached a `dummy` interface per instance
(`ur-vifs.sh`) on the theory that this created distinct egress IPs. **It does
not.** A dummy interface is a local, unroutable address; nothing in the
container or the provider binds to it, and the provider has no flag to select an
egress source IP. That script has been removed. All instances were in fact
egressing over the host address the whole time.

If you want genuinely distinct egress IPs you need one of:

- one provider per physical host / VPS,
- one provider per cheap proxy or tunnel with a real public address,
- a real public IP block routed to you (not a laptop on wifi).

---

## The only file you edit

`.env` — credentials and fleet size:

```env
AUTH=userpass
USER_AUTH=you@example.com
PASSWORD=yourpassword
URNETWORK_INSTANCE_COUNT=6
```

- `AUTH=userpass` — email/password, reusable, boots cleanly every time.
  `AUTH=authcode` + `URNETWORK_AUTH_CODE` is also supported (one-time code; the
  JWT is cached in each node's own volume, consumed once).
- `URNETWORK_INSTANCE_COUNT` — how many providers to run. Default 3.

Optional tuning (defaults are sane; leave unset unless you have a reason):

| Key | Default | Meaning |
|---|---|---|
| `URNETWORK_PROFILE` | `turbo-v8` | `auto`, `eco`, `lowmem`, `turbo-v4`, `turbo-v8`. Higher tiers widen the per-connection TCP window, which is a hard throughput ceiling. |
| `URNETWORK_NOFILE` | `1048576` | Open-file limit for the container. A proxy fleet needs many sockets. |
| `PROXY_FILE` | *(unset)* | Host path to a proxy list; mounted into each container when it has entries. |
| `URNETWORK_SELF_HEAL` | *(unset)* | Set `1` to enable the pressure-adaptive pool controller. |
| `URNETWORK_BANDWIDTH_CAP_KBPS` | `0` | Fleet-wide cap in **KB/s**, enforced as a total and split evenly across containers. `0` or `-1` = no limit. |
| `URNETWORK_MEMORY_CAP_MB` | `0` | Fleet-wide **memory** ceiling in MiB, split evenly. `0` = no limit. |
| `URNETWORK_CPU_CAP_PCT` | `0` | Fleet-wide **CPU** ceiling as percent of host cores, split evenly. `0` = no limit. |
| `PROXY_URL` | *(unset)* | Live proxy feed. Fetched, graded and reaped by the provider. Preferred over a static file. |
| `PROXY_URL_MAX` | `500` | Most proxies admitted from `PROXY_URL`. |
| `PROXY_URL_REFRESH` | `1h` | How often the feed is re-fetched for new entries. |
| `URNETWORK_DIRECT_NODES` | `1` | Nodes `1..N` run residential-only (own IP, no proxies). `0` = all may take proxies. |

The script never echoes credential values, and it does not print them in
errors — a wrong `AUTH` or a missing value is reported by name only.

**Restarting without credentials.** If every node's volume already holds a
valid JWT, the script restarts the fleet with no credentials at all. It does
this by handing the containers `AUTH=authcode`, which is the mode whose
entrypoint accepts a stored session — `AUTH=userpass` always demands
`USER_AUTH`+`PASSWORD` before it looks for a cached JWT. You only need
credentials in `.env` when at least one node has no stored session.

---

## Commands

```sh
sh urnet-start.sh            # bring the fleet up (recreates containers, keeps volumes)
sh urnet-start.sh --status   # live table: profile, proxies, clients, earning, reason
sh urnet-start.sh --stop     # stop all containers, keep volumes
sh urnet-start.sh --kill     # stop AND wipe volumes (new identities)
```

`--status` is the first thing to run when bandwidth looks low. The `PROXIES`
column and the `reason=` field tell you immediately whether the node is idle
for lack of proxies or for another reason.

---

## Memory and CPU ceilings

Both are **totals for the whole fleet**, split evenly across containers, and `0`
means no limit:

```env
URNETWORK_MEMORY_CAP_MB=20000     # 20 GiB for the fleet
URNETWORK_CPU_CAP_PCT=1200        # ~12 cores for the fleet
```

With 6 containers that is 3333 MiB and 200% (~2 cores) each. Shares round
**down**, so the fleet can never exceed the total you set.

`URNETWORK_CPU_CAP_PCT` is percent of host CPUs: `100` = every core once, `200` =
two cores. On a 22-core box, `1200` ≈ 12 cores.

Why Docker and not the provider's own profiles: the provider's tuning profile
sizes buffers from the RAM it thinks it has, and it reads its cgroup limit. A
container limit therefore constrains it correctly, whereas the profile alone
does not cap anything. Memory is set with `--memory` **and** `--memory-swap` to
the same value, which disables swap for the container — a node hitting its
ceiling gets OOM-killed and restarted by `unless-stopped` rather than dragging
the whole host into swap thrash.

Minimum shares are enforced (6 MiB and 10% CPU per container); below that the
script refuses rather than handing Docker a value it rejects.

---

## Bandwidth cap

The provider has **no internal rate limiter** — there is no upstream env var for
this, so the cap is enforced with `tc` on each container's network namespace.

Set a fleet-wide total in `.env`:

```env
URNETWORK_BANDWIDTH_CAP_KBPS=6000  # 6000 KB/s (6 MB/s) for the whole fleet
```

Units are **kilobytes** per second, not kilobits: `1000 KB/s = 1 MB/s = 8 Mbit/s`.

| Value | Meaning |
|---|---|
| `6000` | 6000 KB/s (6 MB/s, ≈48 Mbit/s) total, split evenly across containers |
| `0` | no limit |
| `-1` | no limit (explicit "infinite") |

The cap is a **total**, divided by `URNETWORK_INSTANCE_COUNT`, so raising the
container count lowers each one and the fleet total stays put:

| Cap | 1 node | 3 nodes | 6 nodes | 10 nodes |
|---|---|---|---|---|
| 6000 KB/s | 6000 | 2000 | 1000 | 600 |
| 12000 KB/s | 12000 | 4000 | 2000 | 1200 |

Both directions are shaped: egress with a token bucket on `eth0`, ingress by
redirecting into a per-container `ifb` device.

**Requirements.** `tc` is on the host, not in the image, and entering the
container's netns needs root, so the fleet must be started (or re-capped) as
root:

```sh
sudo sh urnet-start.sh          # start + cap
sudo sh urnet-start.sh --cap    # re-apply a changed cap, no restart
```

`--cap` re-shapes live containers without recreating them, so changing the cap
does not cost a reconnect. Setting the cap to `0`/`-1` and running `--cap`
removes the shaping.

`ifb` must be loadable (`modprobe ifb`). Without it, egress is still capped and
the script warns that ingress shaping is unavailable.

---

## Run on boot

The unit reads `.env` itself. Set `Environment=URNET_REPO=...` in the unit to the
directory holding this repo.

```sh
sudo cp urnet-boot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now urnet-boot.service
```

---

## Host tuning (once, and it matters)

The provider's own docs are explicit that a busy host hits OS limits before it
hits network limits. This sets socket buffers, the fd limit, the ephemeral port
range, and enables BBR:

```sh
urnet-tools optimize
```

Without BBR, TCP congestion control is typically `cubic`; the provider's tuning
guide targets BBR. Check with:

```sh
sysctl net.ipv4.tcp_congestion_control net.netfilter.nf_conntrack_max
```

---

## Verifying it is actually working

```sh
sh urnet-start.sh --status                    # fleet-level view
docker exec urfix-1 urnet-tools proxy summary  # Total proxies: is the lever
docker logs --tail 50 urfix-1                  # [health] and [profit] lines
```

Useful log lines:

- `❤️ [health] ... profile=... proxies=N connections=N` — liveness and tuning
- `[profit] earning=no reason=idle ...` — why it is not earning
- `🌐 [net][s]select: [direct] ...` — one control-plane dial, not relay traffic

---

## Files

| File | Purpose |
|---|---|
| `urnet-start.sh` | Bring the fleet up / status / stop / kill |
| `urnet-boot.service` | systemd unit to run it at boot |
| `.env` | **the only thing you edit** |
| `proxies.txt` | Proxy list — **the bandwidth lever** (see above) |
| `docker-compose.multi.yml` | Reference 3-node compose template (static) |
| `urnetwork-3.23-fix/docs/` | Upstream docs — read `Adding-Proxies.md` and `High-Volume-Performance-Tuning.md` |

---

## Notes

- The provider needs outbound 443 to `api.bringyour.com` /
  `connect.bringyour.com` to authenticate.
- Per-node volumes are separate on purpose: a shared volume would give every
  container the same `.provider.key` and `client_id`, and the backend would
  dedup them into one entry.
- A payout wallet + consent must be set once in the UrNetwork app for earnings
  to be withdrawable. See `docs/Bittensor-Operations.md`.
