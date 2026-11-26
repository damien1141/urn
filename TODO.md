# urnet-start.sh — bandwidth fixes

- [x] Diagnose why bandwidth is low (logs + running containers)
- [x] Read perf docs and confirm which env knobs exist
- [x] Rewrite urnet-start.sh: profile, ulimits, log caps, env-file, metrics ports
- [x] Fix urnet-boot.service wrong path (/ur/ -> /urn/); `systemd-analyze verify` clean
- [x] Remove dead ur-vifs.sh dummy-interface machinery (never bound any egress)
- [x] Update README to stop claiming device IPs; add .env.example
- [x] Add URNETWORK_BANDWIDTH_CAP_MBPS fleet-wide cap (tc, MB/s, 0/-1 = none)
- [x] Add --cap to re-apply without restart; validate + verify tc logic with mocks

## Hardening pass

- [x] Fix --cap calling clear_cap/apply_cap before they were defined
- [x] Fix cap validation letting "-", "1-2", "5-" through to crash arithmetic
- [x] Scale tbf burst with rate (fixed 64kb throttled above ~65 Mbit/s)
- [x] Fix "--stop" blocked by an invalid profile (couldn't stop a broken fleet)
- [x] Fix grep|tail masking failure so "no [profit] line" branch never fired
- [x] Fix cached-JWT path crash-looping the fleet (userpass needs creds)
- [x] Single log read per container in --status; "-" instead of confusing "?"
- [x] Move image pull above the cached-JWT probe that uses the image
- [x] Ship proxies.txt (header-only, RFC 5737 examples, real formats verified)
- [x] Gate the mount on real entry count, not file size
- [x] Fix grep -c "0\n0" bug that broke the entry test
- [x] Wire PROXY_FILE into .env_example + README; drop redundant proxy.txt
- [x] Fleet-wide URNETWORK_MEMORY_CAP_MB (total MiB, split, 0 = none)
- [x] Fleet-wide URNETWORK_CPU_CAP_PCT (total % of cores, split, 0 = none)
- [x] Verify limits land on real containers (3333MiB / 2.00 cpus each)
- [x] Add PROXY_URL live feed support (fetch/grade/reap handled by provider)
- [x] Test Proxifly SOCKS5 feed end-to-end: 5709 -> 83 reachable -> 25 admitted
- [x] Wire feed + 2GiB/600% caps into live fleet; all nodes earning
- [x] Fix require_uint called before definition (same class as clear_cap bug)
- [x] URNETWORK_DIRECT_NODES: pin node #1 to residential (own IP, no proxies)
- [x] Auto-clear persisted proxies on residential nodes (else stays mode=mixed)
- [x] Verify: urfix-1 mode=direct, urfix-2..6 mode=proxies, all earning
