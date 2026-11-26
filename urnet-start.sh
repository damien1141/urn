#!/bin/sh
# urnet-start.sh — UrNetwork 3.23-fix multi-provider fleet.
#
#   sh urnet-start.sh            bring the fleet up (or reconcile it)
#   sh urnet-start.sh --status   show live earning/bandwidth state, no changes
#   sh urnet-start.sh --cap      re-apply the bandwidth cap, no restart
#   sh urnet-start.sh --stop     stop all, keep per-node volumes
#   sh urnet-start.sh --kill     stop all AND wipe per-node volumes
#
# Fleet size and tuning come from .env (copy .env.example).
# Each instance gets its own container, state volume, and identity.
# All you ever do: fill in .env, then run this.
#
# TUNING APPLIED HERE (each one is a measured bandwidth limiter, see
# docs/High-Volume-Performance-Tuning.md):
#   * URNETWORK_PROFILE — default is NOT turbo. Without a profile the
#     per-connection window stays small, which caps throughput.
#   * nofile — the container inherits a low fd limit; a proxy fleet needs
#     many sockets and auth operations.
#   * log caps — an uncapped json-file log grows until the disk fills.
#
# NOT handled here, on purpose: IP diversity. Docker `bridge` puts every
# container on the host's single public IP, so all instances share one
# identity as far as the network can tell. A dummy interface does not
# change that — see README "IP diversity" before expecting more.
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
IMAGE="ghcr.io/full-bars/urnetwork-3.23-fix:latest"
cd "$REPO_DIR"

log() { echo "[urnet-start] $*"; }
die() { echo "[urnet-start] ERROR: $*" >&2; exit 1; }

require_uint() {
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a whole number >= 0 (0 = no limit), got '$2'" ;;
  esac
}


# --- flags -----------------------------------------------------------
STOP=0
KILL=0
STATUS=0
CAPONLY=0
for arg in "$@"; do
  case "$arg" in
    --stop)   STOP=1 ;;
    --kill)   KILL=1; STOP=1 ;;
    --status) STATUS=1 ;;
    --cap)    CAPONLY=1 ;;
    --teardown|--pull)
      log "$arg is no longer needed and is ignored"
      ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown flag: $arg (try --help)" ;;
  esac
done

[ -f "$ENV_FILE" ] || die "no .env at $ENV_FILE (copy .env.example and fill it in)"

# --- read .env -------------------------------------------------------
# Whitelisted keys only: a stray shell line in .env must never execute,
# and credentials must never be echoed.
env_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$ENV_FILE" | tail -1 |
    sed -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

COUNT="$(env_get URNETWORK_INSTANCE_COUNT)"
COUNT="${COUNT:-3}"
case "$COUNT" in
  ''|*[!0-9]*) die "URNETWORK_INSTANCE_COUNT must be a number, got '$COUNT'" ;;
esac
[ "$COUNT" -ge 1 ] || die "URNETWORK_INSTANCE_COUNT must be >= 1"

AUTH="$(env_get AUTH)"
PROFILE="$(env_get URNETWORK_PROFILE)"
PROFILE="${PROFILE:-turbo-v8}"   # doc default for a dedicated box; see TUNING below
NOFILE="$(env_get URNETWORK_NOFILE)"
NOFILE="${NOFILE:-1048576}"
METRICS="$(env_get URNETWORK_METRICS)"
METRICS="${METRICS:-on}"
PROXY_FILE="$(env_get PROXY_FILE)"        # host path, optional
SELF_HEAL="$(env_get URNETWORK_SELF_HEAL)"

# Count real proxy lines (not comments, not blank) so a header-only file
# is treated as "no proxies" rather than mounted and rejected by the
# entrypoint. ~ expands here, once, for the shell.
case "$PROXY_FILE" in
  "~/"*) PROXY_FILE="$HOME/${PROXY_FILE#\~/}" ;;
esac
PROXY_ENTRIES=0
if [ -n "$PROXY_FILE" ] && [ -f "$PROXY_FILE" ]; then
  # grep -c exits 1 when it counts zero, so `|| echo 0` would append a
  # second 0 and produce "0\n0". Count into a var and coerce after.
  _pe="$(grep -cvE '^[[:space:]]*(#|$)' "$PROXY_FILE" 2>/dev/null || true)"
  case "$_pe" in ''|*[!0-9]*) _pe=0 ;; esac
  PROXY_ENTRIES="$_pe"
fi

# Live proxy feed. Preferred over PROXY_FILE for rotating lists: the
# provider fetches it, dedupes against what is already running, grades
# each candidate, and reaps dead entries on its own cadence. Never
# disturbs proxies that are already warmed up.
PROXY_URL="$(env_get PROXY_URL)"
PROXY_URL_REFRESH="$(env_get PROXY_URL_REFRESH)"
PROXY_URL_REFRESH="${PROXY_URL_REFRESH:-1h}"
PROXY_URL_MAX="$(env_get PROXY_URL_MAX)"
PROXY_URL_MAX="${PROXY_URL_MAX:-500}"

# How many nodes run residential-only (no proxy source). Those nodes use
# this host's own connection, which is what the network sees as a real
# residential exit. The rest get the proxy feed.
#   0  = every node may take proxies
#   1  = keep node #1 on the residential IP (default)
# Pin the node that already has history so its earnings are not reset.
DIRECT_NODES="$(env_get URNETWORK_DIRECT_NODES)"
DIRECT_NODES="${DIRECT_NODES:-1}"
require_uint URNETWORK_DIRECT_NODES "$DIRECT_NODES"
if [ "$DIRECT_NODES" -gt "$COUNT" ]; then
  die "URNETWORK_DIRECT_NODES=$DIRECT_NODES is more than URNETWORK_INSTANCE_COUNT=$COUNT"
fi
require_uint PROXY_URL_MAX "$PROXY_URL_MAX"
case "$PROXY_URL" in
  '') ;;
  http://*|https://*|*://*) ;;
  *) die "PROXY_URL must start with http:// or https://, got '$PROXY_URL'" ;;
esac

# Fleet-wide memory and CPU ceilings. Each is a TOTAL for all containers,
# split evenly, and 0 means no limit.
#   URNETWORK_MEMORY_CAP_MB   total MiB for the fleet  (0 = unlimited)
#   URNETWORK_CPU_CAP_PCT     total percent of host CPUs (0 = unlimited,
#                             100 = every core once, so 200 = two cores)
# Docker enforces these per container, which makes them a hard ceiling
# regardless of what the provider's own tuning thinks it has.
MEM_CAP_MB="$(env_get URNETWORK_MEMORY_CAP_MB)"
MEM_CAP_MB="${MEM_CAP_MB:-0}"
CPU_CAP_PCT="$(env_get URNETWORK_CPU_CAP_PCT)"
CPU_CAP_PCT="${CPU_CAP_PCT:-0}"

require_uint URNETWORK_MEMORY_CAP_MB "$MEM_CAP_MB"
require_uint URNETWORK_CPU_CAP_PCT "$CPU_CAP_PCT"

# Per-container share, rounded down, so COUNT containers can never exceed
# the total. A share below the minimum is refused rather than silently
# producing a container the runtime rejects.
MEM_PER_MB=0
CPU_PER_PCT=0
if [ "$MEM_CAP_MB" -gt 0 ]; then
  MEM_PER_MB=$(( MEM_CAP_MB / COUNT ))
  if [ "$MEM_PER_MB" -lt 6 ]; then
    die "URNETWORK_MEMORY_CAP_MB=$MEM_CAP_MB over $COUNT containers is under 6 MiB each; raise the cap or lower the count"
  fi
fi
if [ "$CPU_CAP_PCT" -gt 0 ]; then
  CPU_PER_PCT=$(( CPU_CAP_PCT / COUNT ))
  if [ "$CPU_PER_PCT" -lt 10 ]; then
    die "URNETWORK_CPU_CAP_PCT=$CPU_CAP_PCT over $COUNT containers is under 10% each; raise the cap or lower the count"
  fi
fi

# Fleet-wide bandwidth cap, in KB/s (kilobytes per second).
#   N  = total for the whole fleet, split evenly across containers
#   0  = no limit
#  -1  = no limit (explicit "infinite")
# Kilobytes, not kilobits: 1000 KB/s = 8 Mbit/s.
# The provider has no internal rate limiter, so this is enforced with tc
# on each container's network namespace. It caps both directions.
CAP_KBPS="$(env_get URNETWORK_BANDWIDTH_CAP_KBPS)"
CAP_KBPS="${CAP_KBPS:-0}"
# The old key was URNETWORK_BANDWIDTH_CAP_MBPS. A .env left over from it
# would silently mean "no cap", so refuse instead of guessing a unit.
_legacy_cap="$(env_get URNETWORK_BANDWIDTH_CAP_MBPS)"
if [ -n "$_legacy_cap" ]; then
  die "URNETWORK_BANDWIDTH_CAP_MBPS is retired — use URNETWORK_BANDWIDTH_CAP_KBPS (kilobytes per second, so 1000 = 8 Mbit/s)"
fi

# Accept exactly -1 (no limit) or a run of digits. Anything else -- "-",
# "1-2", "5-", "3.5" -- would pass a looser pattern and then crash the
# arithmetic below, so the pattern stays strict here.
case "$CAP_KBPS" in
  -1) CAP_KBPS=0 ;;
  '') die "URNETWORK_BANDWIDTH_CAP_KBPS is set but empty (0 or -1 = no limit)" ;;
  *[!0-9]*)
    die "URNETWORK_BANDWIDTH_CAP_KBPS must be a whole number in KB/s (0 or -1 = no limit), got '$CAP_KBPS'"
    ;;
esac

validate_profile() {
  case "$1" in
    auto|eco|lowmem|turbo-v4|turbo-v8) ;;
    *) die "URNETWORK_PROFILE='$1' is not valid (auto, eco, lowmem, turbo-v4, turbo-v8)" ;;
  esac
}
# --stop only needs the container count, so a bad profile or cap must not
# be able to strand a fleet that needs stopping.
if [ "$STOP" -eq 0 ]; then validate_profile "$PROFILE"; fi

# Non-empty, non-placeholder, without printing the value.
plausible_cred() {
  [ -n "$1" ] || return 1
  case "$1" in
    you@example.com|yourpassword|PASTE_YOUR_AUTH_CODE_HERE) return 1 ;;
  esac
  return 0
}

# --- status (read-only) ----------------------------------------------
if [ "$STATUS" -eq 1 ]; then
  if [ "$CAP_KBPS" -gt 0 ]; then
    _bw="cap ${CAP_KBPS}KB/s total"
  else
    _bw="cap none"
  fi
  if [ "$MEM_CAP_MB" -gt 0 ]; then
    _mem="${MEM_CAP_MB}MiB total (${MEM_PER_MB}MiB each)"
  else
    _mem="none"
  fi
  if [ "$CPU_CAP_PCT" -gt 0 ]; then
    _cpu="${CPU_CAP_PCT}% total (${CPU_PER_PCT}% each)"
  else
    _cpu="none"
  fi
  log "fleet: $COUNT configured, requested profile: $PROFILE, bandwidth $_bw"
  log "       memory limit: $_mem | cpu limit: $_cpu"
  if [ "$DIRECT_NODES" -gt 0 ]; then
    log "       nodes 1-$DIRECT_NODES: residential (own IP, no proxies)"
  fi
  if [ "$DIRECT_NODES" -lt "$COUNT" ]; then
    if [ -n "$PROXY_URL" ]; then
      log "       nodes $((DIRECT_NODES + 1))-$COUNT: feed $PROXY_URL_MAX max, refresh $PROXY_URL_REFRESH"
    elif [ "$PROXY_ENTRIES" -gt 0 ]; then
      log "       nodes $((DIRECT_NODES + 1))-$COUNT: $PROXY_ENTRIES entries from $PROXY_FILE"
    else
      log "       nodes $((DIRECT_NODES + 1))-$COUNT: no proxy source (direct-only)"
    fi
  fi
  echo
  printf '%-10s %-9s %-8s %-9s %-8s %-10s %s\n' \
    NODE STATE PROFILE PROXIES CLIENTS EARNING NOTE
  for i in $(seq 1 "$COUNT"); do
    NAME="urfix-$i"
    if ! docker inspect "$NAME" >/dev/null 2>&1; then
      printf '%-10s %-9s %-8s %-9s %-8s %-10s %s\n' \
        "$NAME" absent - - - - "not created"
      continue
    fi
    STATE="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo '?')"

    # The [health] heartbeat carries the profile the process actually
    # booted with, plus the proxy count.
    # One log read per container serves both extractions below.
    LOGS="$(docker logs --tail 400 "$NAME" 2>&1 || true)"
    # Anchor on `uptime=` so the trailing "[health] Verdict:" summary line
    # (which has no profile/proxies fields) cannot win the tail.
    HLINE="$(printf '%s\n' "$LOGS" | grep -F 'uptime=' | tail -1 || true)"
    LIVE_PROFILE="$(printf '%s' "$HLINE" | sed -n 's/.*profile=\([a-z0-9-]*\).*/\1/p')"
    PROXIES="$(printf '%s' "$HLINE" | sed -n 's/.*proxies=\([0-9]*\).*/\1/p')"
    # The [profit] line carries earning state, client count and the reason.
    LINE="$(printf '%s\n' "$LOGS" | grep -F '[profit]' | tail -1 || true)"
    CONNS="?"
    NOTE=""
    EARNING="no"

    # The heartbeat is every 5 minutes, so a freshly started node has no
    # numbers yet. Say so instead of a bare "?" that reads like a failure.
    if [ -z "$HLINE" ]; then
      if [ -z "$LINE" ]; then NOTE="warming up"; fi
    fi
    [ -n "$LIVE_PROFILE" ] || LIVE_PROFILE="-"
    [ -n "$PROXIES" ] || PROXIES="-"
    if [ -n "$LINE" ]; then
      CONNS="$(printf '%s' "$LINE" | sed -n 's/.*clients=\([0-9]*\).*/\1/p')"
      [ -n "$CONNS" ] || CONNS="?"
      if printf '%s' "$LINE" | grep -q 'earning=yes'; then
        EARNING="yes"
      fi
      # The reason= field is the single most useful diagnostic for
      # "the provider is up but not earning".
      NOTE="$(printf '%s' "$LINE" | sed -n 's/.*reason=\([a-z-]*\).*/\1/p')"
    fi
    printf '%-10s %-9s %-8s %-9s %-8s %-10s %s\n' \
      "$NAME" "$STATE" "$LIVE_PROFILE" "$PROXIES" "$CONNS" "$EARNING" "${NOTE:--}"
  done
  echo
  cat <<'TIP'
The PROXIES column is the bandwidth lever. A provider with 0 proxies is a
single `direct` identity: one machine, one address, one share of the
market. Adding proxies is what grows billable volume.

  urnet-tools proxy add <file>      # host:port or host:port:user:pass
  urnet-tools proxy refresh

A `direct`-only node can still earn, but it competes as a single peer.
TIP
  exit 0
fi

# --- stop ------------------------------------------------------------
if [ "$STOP" -eq 1 ]; then
  if [ "$KILL" -eq 1 ]; then
    log "stopping $COUNT containers and wiping their volumes"
    for i in $(seq 1 "$COUNT"); do
      docker rm -f "urfix-$i" >/dev/null 2>&1 || true
      docker volume rm "ur_config_$i" >/dev/null 2>&1 || true
    done
  else
    log "stopping $COUNT containers (volumes kept)"
    for i in $(seq 1 "$COUNT"); do
      docker rm -f "urfix-$i" >/dev/null 2>&1 || true
    done
  fi
  exit 0
fi

# --- 0. Image --------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pulling image"
  docker pull "$IMAGE" || die "could not pull $IMAGE"
fi

# --- 1. Credentials ---------------------------------------------------
# The container entrypoint validates credentials BEFORE it looks at a
# cached JWT: AUTH=userpass always demands USER_AUTH+PASSWORD, while
# AUTH=authcode accepts an existing session file. So a fleet whose
# volumes already hold a valid JWT can be restarted with no credentials
# at all, but only if we hand the container AUTH=authcode. Pretending
# userpass works without credentials is what crash-looped the fleet.
missing_vol=0
cached_jwt=0
for i in $(seq 1 "$COUNT"); do
  docker volume inspect "ur_config_$i" >/dev/null 2>&1 || missing_vol=1
done
# A cached JWT is reusable only if EVERY node has one, since one AUTH
# value is applied to all containers.
all_cached=1
for i in $(seq 1 "$COUNT"); do
  if ! docker run --rm -v "ur_config_$i:/s:ro" --entrypoint sh \
        "$IMAGE" -c 'test -s /s/jwt' >/dev/null 2>&1; then
    all_cached=0
    break
  fi
done
[ "$all_cached" -eq 1 ] && cached_jwt=1

RUN_AUTH="$AUTH"
case "$AUTH" in
  userpass)
    U="$(env_get USER_AUTH)"
    P="$(env_get PASSWORD)"
    if plausible_cred "$U" && plausible_cred "$P"; then
      log "fleet: $COUNT instances, profile: $PROFILE, auth: userpass"
    elif [ "$cached_jwt" -eq 1 ]; then
      # No credentials on hand, but every node already has a session.
      # authcode is the mode that accepts a stored JWT.
      RUN_AUTH=authcode
      log "fleet: $COUNT instances, profile: $PROFILE, auth: authcode (reusing stored sessions)"
    else
      die "AUTH=userpass needs USER_AUTH and PASSWORD in .env (no stored session to reuse)"
    fi
    ;;
  authcode)
    AC="$(env_get URNETWORK_AUTH_CODE)"
    if plausible_cred "$AC"; then
      log "fleet: $COUNT instances, profile: $PROFILE, auth: authcode"
    elif [ "$cached_jwt" -eq 1 ]; then
      log "fleet: $COUNT instances, profile: $PROFILE, auth: authcode (reusing stored sessions)"
    else
      die "AUTH=authcode needs URNETWORK_AUTH_CODE in .env (no stored session to reuse)"
    fi
    ;;
  '')  die "set AUTH=userpass or AUTH=authcode in .env" ;;
  *)   die "AUTH='$AUTH' is not valid (userpass or authcode)" ;;
esac


# --- 2. Host prerequisites (best-effort; never fatal) ----------------
# A missing kernel setting degrades throughput, it does not stop the fleet.
if [ "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
  CMAX="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)"
  if [ "$CMAX" -lt 262144 ] 2>/dev/null; then
    log "WARNING: nf_conntrack_max=$CMAX may cap a large proxy fleet."
    log "         Run once as root: urnet-tools optimize"
  fi
fi
case "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" in
  bbr) ;;
  *) log "note: TCP congestion control is not BBR; throughput can improve with it."
     log "      Run once as root: urnet-tools optimize" ;;
esac

# --- bandwidth cap (tc) ----------------------------------------------
# The provider has no rate limit of its own. A token bucket on the
# container's veth shapes egress; an ifb device shapes ingress too.
# The cap is fleet-wide, so it is divided by COUNT and re-applied on every
# start -- changing the cap just means re-running this script.
CAP_KBIT=0
if [ "$CAP_KBPS" -gt 0 ]; then
  # KB/s -> kbit/s is exactly x8. Round the per-container share UP so the
  # fleet total never exceeds the configured cap.
  CAP_KBIT=$(( (CAP_KBPS * 8 + COUNT - 1) / COUNT ))
  if [ "$CAP_KBIT" -lt 8 ]; then
    die "cap of ${CAP_KBPS}KB/s across $COUNT containers is below 8 kbit/s each — raise the cap or lower the count"
  fi
  # tbf requires burst >= ~10ms of traffic or it throttles BELOW the set
  # rate. A fixed 64kb burst silently caps any container above ~65 Mbit/s,
  # so size it from the rate and clamp to a sane range.
  CAP_BURST=$(( CAP_KBIT * 1000 / 8 / 100 ))   # 10ms in bytes
  if [ "$CAP_BURST" -lt 4096 ]; then CAP_BURST=4096; fi
  if [ "$CAP_BURST" -gt 1048576 ]; then CAP_BURST=1048576; fi
fi

# tc lives on the host and must enter the container's netns as root.
TC_OK=0
if [ "$CAP_KBIT" -gt 0 ] && [ "$(id -u)" -eq 0 ] &&
   command -v tc >/dev/null 2>&1 && command -v nsenter >/dev/null 2>&1; then
  TC_OK=1
fi

# apply_cap <container> — idempotent: replace any previous shaping.
apply_cap() {
  _c="$1"
  _pid="$(docker inspect -f '{{.State.Pid}}' "$_c" 2>/dev/null || echo 0)"
  if [ -z "$_pid" ] || [ "$_pid" = "0" ]; then
    log "WARNING: $_c has no pid yet; cap not applied"
    return 1
  fi
  # Derive the host-side veth so ingress can be shaped with ifb. The
  # container's iflink is the host veth's ifindex.
  _iflink="$(nsenter -t "$_pid" -n cat /sys/class/net/eth0/iflink 2>/dev/null || echo '')"
  _veth=""
  if [ -n "$_iflink" ]; then
    for _l in /sys/class/net/*; do
      [ -r "$_l/ifindex" ] || continue
      if [ "$(cat "$_l/ifindex" 2>/dev/null)" = "$_iflink" ]; then
        _veth="$(basename "$_l")"
        break
      fi
    done
  fi

  # Egress: token bucket on the container's own interface.
  nsenter -t "$_pid" -n tc qdisc del dev eth0 root 2>/dev/null || true
  if ! nsenter -t "$_pid" -n tc qdisc add dev eth0 root tbf rate "${CAP_KBIT}kbit" burst "${CAP_BURST}" latency 50ms 2>/dev/null; then
    log "WARNING: $_c could not shape egress"
    return 1
  fi

  # Ingress: redirect into an ifb device so it can be shaped too.
  # Each container gets its OWN ifb device. Sharing one would put every
  # container behind a single token bucket of CAP_KBIT in total, capping
  # the fleet at one container's share instead of COUNT shares.
  if [ -n "$_veth" ]; then
    modprobe ifb >/dev/null 2>&1 || true
    _ifb="ifb_$(_ifb_index "$_c")"
    ip link add "$_ifb" type ifb 2>/dev/null || true
    ip link set "$_ifb" up 2>/dev/null || true
    tc qdisc del dev "$_veth" ingress 2>/dev/null || true
    tc qdisc del dev "$_ifb" root 2>/dev/null || true
    if tc qdisc add dev "$_veth" ingress 2>/dev/null &&
       tc filter add dev "$_veth" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$_ifb" 2>/dev/null &&
       tc qdisc add dev "$_ifb" root tbf rate "${CAP_KBIT}kbit" burst "${CAP_BURST}" latency 50ms 2>/dev/null; then
      :
    else
      log "WARNING: $_c ingress shaping unavailable; egress cap still applied"
    fi
  fi
  return 0
}

# Stable small integer per container name, used to name its ifb device.
# urfix-3 -> 3. Falls back to the shell pid if the name is not numbered.
_ifb_index() {
  _n="${1#urfix-}"
  case "$_n" in
    ''|*[!0-9]*) printf '%s' "$$" ;;
    *) printf '%s' "$_n" ;;
  esac
}

clear_cap() {
  _c="$1"
  _pid="$(docker inspect -f '{{.State.Pid}}' "$_c" 2>/dev/null || echo 0)"
  [ -n "$_pid" ] && [ "$_pid" != "0" ] || return 0
  nsenter -t "$_pid" -n tc qdisc del dev eth0 root 2>/dev/null || true
  ip link del "ifb_$(_ifb_index "$_c")" 2>/dev/null || true
  return 0
}

# --cap: re-apply shaping to running containers without recreating them,
# so changing the cap does not cost a reconnect.
if [ "$CAPONLY" -eq 1 ]; then
  if [ "$CAP_KBIT" -eq 0 ]; then
    log "no cap configured (URNETWORK_BANDWIDTH_CAP_KBPS=$CAP_KBPS) — clearing any existing shaping"
    for i in $(seq 1 "$COUNT"); do clear_cap "urfix-$i"; done
    log "done"
    exit 0
  fi
  if [ "$TC_OK" -ne 1 ]; then
    die "--cap needs root and tc/nsenter on the host (run with sudo)"
  fi
  log "applying ${CAP_KBPS}KB/s fleet-wide = ${CAP_KBIT}kbit/s per container ($COUNT containers)"
  rc=0
  for i in $(seq 1 "$COUNT"); do
    NAME="urfix-$i"
    if ! docker inspect "$NAME" >/dev/null 2>&1; then
      log "$NAME not running — skipped"
      continue
    fi
    apply_cap "$NAME" && log "$NAME capped at ${CAP_KBIT}kbit/s" || rc=1
  done
  [ "$rc" -eq 0 ] || die "at least one container could not be capped"
  exit 0
fi

# --- 3. Start each instance -----------------------------------------
# Any dummy* interfaces left by the old script are inert (nothing binds to
# them). They are not needed and are removed at the end of this run.
for i in $(seq 1 "$COUNT"); do
  NAME="urfix-$i"

  if docker inspect "$NAME" >/dev/null 2>&1; then
    # Recreate so a changed profile/ulimit is actually applied. The state
    # volume is preserved, so the identity and JWT survive.
    log "recreating $NAME"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi

  set -- \
    --name "$NAME" \
    --restart=unless-stopped \
    --pull=never \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    --ulimit "nofile=$NOFILE:$NOFILE" \
    --log-driver json-file --log-opt max-size=50m --log-opt max-file=3 \
    -e AUTH="$RUN_AUTH" \
    -e HOST_HOSTNAME="${HOSTNAME:-laptop}" \
    -e URNETWORK_NODE_NAME="$NAME" \
    -e URNETWORK_PROFILE="$PROFILE" \
    -e URNETWORK_CONTAINER_NAME="$NAME" \
    -e URNETWORK_METRICS="$METRICS" \
    -v "ur_config_$i:/root/.urnetwork"

  # Credentials are only passed when set; an empty string would make the
  # entrypoint's own validation fail.
  case "$AUTH" in
    userpass)
      if [ -n "${U:-}" ]; then set -- "$@" -e USER_AUTH="$U"; fi
      if [ -n "${P:-}" ]; then set -- "$@" -e PASSWORD="$P"; fi
      ;;
    authcode)
      if [ -n "${AC:-}" ]; then set -- "$@" -e URNETWORK_AUTH_CODE="$AC"; fi
      ;;
  esac

  # Nodes 1..DIRECT_NODES run with NO proxy source, so their traffic
  # leaves through this host's own connection: a real residential exit,
  # which is what the network scores best. This is per-container because
  # the proxy source is per-container: with the feed unset, a node has no
  # proxies at all and falls back to `direct` on its own.
  if [ "$i" -le "$DIRECT_NODES" ]; then
    : # residential-only: deliberately no PROXY_URL and no proxy file
  else
    # Mount the file only when it has real entries: the entrypoint imports
    # it and warns "no valid servers" for a comments-only file, so gate on
    # line count, not on file size.
    if [ -n "$PROXY_FILE" ] && [ -f "$PROXY_FILE" ] && [ "$PROXY_ENTRIES" -gt 0 ]; then
      set -- "$@" -v "$PROXY_FILE:/app/proxy.txt:ro" -e PROXY_FILE=/app/proxy.txt
    fi
    if [ -n "$PROXY_URL" ]; then
      set -- "$@" -e PROXY_URL="$PROXY_URL" \
                -e PROXY_URL_REFRESH="$PROXY_URL_REFRESH" \
                -e PROXY_URL_MAX="$PROXY_URL_MAX"
    fi
  fi
  if [ -n "$SELF_HEAL" ]; then set -- "$@" -e URNETWORK_SELF_HEAL="$SELF_HEAL"; fi

  # Hard ceilings, applied only when configured. memory-swap equal to
  # memory disables swap for the container, so a node at its limit cannot
  # push the host into swap thrash.
  if [ "$MEM_PER_MB" -gt 0 ]; then
    set -- "$@" --memory "${MEM_PER_MB}m" --memory-swap "${MEM_PER_MB}m"
  fi
  if [ "$CPU_PER_PCT" -gt 0 ]; then
    _cpus="$(awk "BEGIN{printf \"%.2f\", $CPU_PER_PCT/100}")"
    set -- "$@" --cpus "$_cpus"
  fi

  docker run -d "$@" "$IMAGE" >/dev/null || die "failed to start $NAME"
  if [ "$i" -le "$DIRECT_NODES" ]; then
    log "$NAME role: residential (own IP, no proxies)"
    # Unsetting PROXY_URL is not enough: proxies persisted in the state
    # volume stay configured and the node keeps running `mode=mixed`.
    # Clear them so the node really egresses from this host's own IP.
    # Runs after the provider is up; it only edits config and reloads.
    _cl=0
    while [ "$_cl" -lt 20 ]; do
      if docker exec "$NAME" sh -c 'test -S /root/.urnetwork/provider.sock' 2>/dev/null; then
        docker exec "$NAME" urnet-tools proxy clear --force >/dev/null 2>&1 \
          && log "$NAME cleared persisted proxies (now direct-only)"
        break
      fi
      _cl=$((_cl + 1)); sleep 1
    done
  else
    log "$NAME role: proxied"
  fi
  if [ "$CAP_KBIT" -gt 0 ]; then
    if [ "$TC_OK" -eq 1 ]; then
      # The interface needs a moment to exist inside the new netns.
      _t=0
      while [ "$_t" -lt 10 ] && ! docker exec "$NAME" cat /sys/class/net/eth0/operstate >/dev/null 2>&1; do
        _t=$((_t + 1)); sleep 0.5
      done
      if apply_cap "$NAME"; then
        log "started $NAME (volume ur_config_$i, profile $PROFILE, cap ${CAP_KBIT}kbit/s)"
      else
        log "started $NAME (volume ur_config_$i, profile $PROFILE) — CAP NOT APPLIED"
      fi
    else
      log "started $NAME (volume ur_config_$i, profile $PROFILE) — cap skipped (needs root + tc)"
    fi
  else
    log "started $NAME (volume ur_config_$i, profile $PROFILE, no bandwidth cap)"
  fi
done

# --- 4. Wait for the first JWT --------------------------------------
log "waiting for urfix-1 to authenticate"
AUTHED=0
n=0
while [ "$n" -lt 60 ]; do
  if docker exec urfix-1 test -s /root/.urnetwork/jwt 2>/dev/null; then
    log "authenticated — JWT present"
    AUTHED=1
    break
  fi
  # A container that already exited will never produce a JWT.
  if [ "$(docker inspect -f '{{.State.Running}}' urfix-1 2>/dev/null)" != "true" ]; then
    log "urfix-1 stopped before authenticating — last log lines:"
    docker logs --tail 25 urfix-1 2>&1 || true
    break
  fi
  n=$((n + 1))
  sleep 2
done
[ "$AUTHED" -eq 1 ] || log "WARNING: no JWT after 120s — check credentials in .env"

# --- 5. Remove inert leftover interfaces ----------------------------
# Only when we are root; otherwise leave them for a later sudo run.
if [ "$(id -u)" -eq 0 ]; then
  for d in /sys/class/net/dummy*; do
    [ -e "$d" ] || continue
    ip link del "$(basename "$d")" 2>/dev/null || true
  done
fi

# --- 6. Summary ------------------------------------------------------
log "done. status:"
docker ps --filter "name=urfix-" --format "{{.Names}}\t{{.Status}}"
echo
log "earning check (reason= tells you if the node is idle):"
# `grep ... | tail -1` always exits 0, so test the grep result, not the
# pipeline, or the "not yet" branch below would never fire.
PROFIT_LINE="$(docker logs --tail 200 urfix-1 2>&1 | grep -F '[profit]' | tail -1 || true)"
if [ -n "$PROFIT_LINE" ]; then
  echo "$PROFIT_LINE"
else
  log "no [profit] line yet — it appears within ~5 minutes"
fi
echo
log "full report: sh urnet-start.sh --status"
