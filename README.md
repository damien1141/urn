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
identities and the volume routed to you:

```sh
urnet-tools proxy add ~/proxies.txt   # host:port or host:port:user:pass
urnet-tools proxy refresh
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
| `URNETWORK_BANDWIDTH_CAP_MBPS` | `0` | Fleet-wide cap in **MB/s**, enforced as a total and split evenly across containers. `0` or `-1` = no limit. |

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

## Bandwidth cap

The provider has **no internal rate limiter** — there is no upstream env var for
this, so the cap is enforced with `tc` on each container's network namespace.

Set a fleet-wide total in `.env`:

```env
URNETWORK_BANDWIDTH_CAP_MBPS=6     # 6 MB/s for the whole fleet
```

Units are **megabytes** per second, not megabits. `1 MB/s = 8 Mbit/s`.

| Value | Meaning |
|---|---|
| `6` | 6 MB/s total (≈48 Mbit/s), split evenly across containers |
| `0` | no limit |
| `-1` | no limit (explicit "infinite") |

The cap is a **total**, divided by `URNETWORK_INSTANCE_COUNT`, so raising the
container count lowers each one and the fleet total stays put:

| Cap | 1 node | 3 nodes | 6 nodes | 10 nodes |
|---|---|---|---|---|
| 6 MB/s | 6 MB/s | 2 MB/s | 1 MB/s | 0.6 MB/s |
| 12 MB/s | 12 MB/s | 4 MB/s | 2 MB/s | 1.2 MB/s |

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
| `proxy.txt` | Proxy list template (one per line) |
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
