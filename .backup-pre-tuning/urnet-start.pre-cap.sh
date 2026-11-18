#!/bin/sh
# urnet-start.sh — UrNetwork 3.23-fix multi-provider fleet.
#
#   sh urnet-start.sh            bring the fleet up (or reconcile it)
#   sh urnet-start.sh --status   show live earning/bandwidth state, no changes
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

# --- flags -----------------------------------------------------------
STOP=0
KILL=0
STATUS=0
for arg in "$@"; do
  case "$arg" in
    --stop)   STOP=1 ;;
    --kill)   KILL=1; STOP=1 ;;
    --status) STATUS=1 ;;
    --teardown|--pull)
      log "$arg is no longer needed and is ignored"
      ;;
    -h|--help)
      sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
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

validate_profile() {
  case "$1" in
    auto|eco|lowmem|turbo-v4|turbo-v8) ;;
    *) die "URNETWORK_PROFILE='$1' is not valid (auto, eco, lowmem, turbo-v4, turbo-v8)" ;;
  esac
}
validate_profile "$PROFILE"

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
  log "fleet: $COUNT configured, requested profile: $PROFILE"
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
    # Anchor on `uptime=` so the trailing "[health] Verdict:" summary line
    # (which has no profile/proxies fields) cannot win the tail.
    HLINE="$(docker logs --tail 400 "$NAME" 2>&1 |
      grep -F 'uptime=' | tail -1)"
    LIVE_PROFILE="$(printf '%s' "$HLINE" | sed -n 's/.*profile=\([a-z0-9-]*\).*/\1/p')"
    [ -n "$LIVE_PROFILE" ] || LIVE_PROFILE="?"
    PROXIES="$(printf '%s' "$HLINE" | sed -n 's/.*proxies=\([0-9]*\).*/\1/p')"
    [ -n "$PROXIES" ] || PROXIES="?"

    # The [profit] line carries earning state, client count and the reason.
    LINE="$(docker logs --tail 400 "$NAME" 2>&1 |
      grep -F '[profit]' | tail -1)"
    CONNS="?"
    NOTE=""
    EARNING="no"
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

# --- 0. Credentials --------------------------------------------------
# Checked only when the fleet has to authenticate, so a running fleet can
# be restarted without credentials that are already cached in its volumes.
need_creds=0
for i in $(seq 1 "$COUNT"); do
  docker volume inspect "ur_config_$i" >/dev/null 2>&1 || need_creds=1
done

case "$AUTH" in
  userpass)
    U="$(env_get USER_AUTH)"
    P="$(env_get PASSWORD)"
    if [ "$need_creds" -eq 1 ]; then
      plausible_cred "$U" || die "AUTH=userpass needs a real USER_AUTH in .env"
      plausible_cred "$P" || die "AUTH=userpass needs a real PASSWORD in .env"
      log "fleet: $COUNT instances, profile: $PROFILE, auth: userpass"
    else
      log "fleet: $COUNT instances, profile: $PROFILE, auth: userpass (cached sessions reusable)"
    fi
    ;;
  authcode)
    AC="$(env_get URNETWORK_AUTH_CODE)"
    if [ "$need_creds" -eq 1 ]; then
      plausible_cred "$AC" || die "AUTH=authcode needs URNETWORK_AUTH_CODE in .env"
      log "fleet: $COUNT instances, profile: $PROFILE, auth: authcode"
    else
      log "fleet: $COUNT instances, profile: $PROFILE, auth: authcode (cached sessions reusable)"
    fi
    ;;
  '')     die "set AUTH=userpass or AUTH=authcode in .env" ;;
  *)      die "AUTH='$AUTH' is not valid (userpass or authcode)" ;;
esac

# --- 1. Image --------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pulling image"
  docker pull "$IMAGE" || die "could not pull $IMAGE"
fi

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
    -e AUTH="$AUTH" \
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

  # A proxy source is the difference between "provider is up" and
  # "provider is earning". Mount it when the file exists and has entries.
  if [ -n "$PROXY_FILE" ] && [ -s "$PROXY_FILE" ]; then
    set -- "$@" -v "$PROXY_FILE:/app/proxy.txt:ro" -e PROXY_FILE=/app/proxy.txt
  fi
  if [ -n "$SELF_HEAL" ]; then set -- "$@" -e URNETWORK_SELF_HEAL="$SELF_HEAL"; fi

  docker run -d "$@" "$IMAGE" >/dev/null || die "failed to start $NAME"
  log "started $NAME (volume ur_config_$i, profile $PROFILE)"
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
if ! docker logs --tail 200 urfix-1 2>&1 | grep -F '[profit]' | tail -1; then
  log "no [profit] line yet — it appears within ~5 minutes"
fi
echo
log "full report: sh urnet-start.sh --status"
