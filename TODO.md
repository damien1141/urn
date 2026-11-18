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
