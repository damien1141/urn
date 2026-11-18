#!/bin/sh
# urnet-start.sh — UrNetwork 3.23-fix multi-provider.
#
#   sh urnet-start.sh                bring the fleet up
#   sh urnet-start.sh --stop        stop all, keep per-node volumes
#   sh urnet-start.sh --kill        stop all AND wipe per-node volumes
#   sh urnet-start.sh --teardown    tear down the virtual interfaces
#
# Fleet size comes from URNETWORK_INSTANCE_COUNT in .env (default 3).
# Each instance gets its own container, state volume, and device IP.
# All you ever do: fill in credentials + count in .env, then run this.
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
VIF_SCRIPT="$REPO_DIR/ur-vifs.sh"
IMAGE="ghcr.io/full-bars/urnetwork-3.23-fix:latest"
cd "$REPO_DIR"

log() { echo "[urnet-start] $*"; }

# --- flags -----------------------------------------------------------
STOP=0
KILL=0
TEARDOWN=0
for arg in "$@"; do
  case "$arg" in
    --stop)     STOP=1 ;;
    --kill)     KILL=1; STOP=1 ;;
    --teardown) TEARDOWN=1 ;;
    *) log "unknown flag: $arg"; exit 1 ;;
  esac
done

if [ "$TEARDOWN" -eq 1 ]; then
  log "tearing down virtual interfaces"
  sh "$VIF_SCRIPT" teardown
  exit 0
fi

# --- read .env -------------------------------------------------------
eval "$(awk '/^[A-Z_]+=/ { print }' "$ENV_FILE")"
COUNT="${URNETWORK_INSTANCE_COUNT:-3}"
case "$COUNT" in
  ''|*[!0-9]*) log "ERROR: URNETWORK_INSTANCE_COUNT must be a number, got '$COUNT'"; exit 1 ;;
esac
if [ "$COUNT" -lt 1 ]; then log "ERROR: URNETWORK_INSTANCE_COUNT must be >= 1"; exit 1; fi

if [ "$STOP" -eq 1 ]; then
  if [ "$KILL" -eq 1 ]; then
    log "stopping $COUNT containers and wiping their volumes"
    for i in $(seq 1 "$COUNT"); do
      docker rm -f "urfix-$i" 2>/dev/null || true
    done
    for i in $(seq 1 "$COUNT"); do
      docker volume rm "ur_config_$i" 2>/dev/null || true
    done
  else
    log "stopping $COUNT containers (volumes kept)"
    for i in $(seq 1 "$COUNT"); do
      docker stop "urfix-$i" 2>/dev/null || true
    done
  fi
  exit 0
fi

# --- 0. Sanity: credentials filled in? -------------------------------
case "${AUTH:-}" in
  userpass)
    if [ -z "${USER_AUTH:-}" ] || [ "$USER_AUTH" = "you@example.com" ] \
       || [ -z "${PASSWORD:-}" ] || [ "$PASSWORD" = "yourpassword" ]; then
      log "ERROR: set USER_AUTH and PASSWORD in .env"; exit 1
    fi
    log "fleet: $COUNT instances, auth mode: userpass ($USER_AUTH)"
    ;;
  authcode)
    if [ -z "${URNETWORK_AUTH_CODE:-}" ] || [ "$URNETWORK_AUTH_CODE" = "PASTE_YOUR_AUTH_CODE_HERE" ]; then
      log "ERROR: set URNETWORK_AUTH_CODE in .env"; exit 1
    fi
    log "fleet: $COUNT instances, auth mode: authcode"
    ;;
  *)
    log "ERROR: set AUTH=userpass or AUTH=authcode in .env"; exit 1
    ;;
esac

# --- 1. Virtual interfaces (one per instance) -----------------------
log "setting up $COUNT virtual interfaces"
if [ "$(id -u)" -ne 0 ]; then
  log "needs root for ip link — retrying with sudo"
  exec sudo "$0" "$@"
fi
sh "$VIF_SCRIPT" "$COUNT"

# --- 2. Ensure image is present -------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "pulling image"
  docker pull "$IMAGE"
fi

# --- 3. Start each instance (own container + volume + device IP) ----
for i in $(seq 1 "$COUNT"); do
  NAME="urfix-$i"
  if docker inspect "$NAME" >/dev/null 2>&1; then
    log "container $NAME exists — removing to rebind volume"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
  docker run -d \
    --name "$NAME" \
    --restart=unless-stopped \
    --pull=never \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    -e HOST_HOSTNAME="${HOSTNAME:-laptop}" \
    -e URNETWORK_NODE_NAME="$NAME" \
    -e AUTH="$AUTH" \
    -e USER_AUTH="${USER_AUTH:-}" \
    -e PASSWORD="${PASSWORD:-}" \
    -e URNETWORK_AUTH_CODE="${URNETWORK_AUTH_CODE:-}" \
    -v "ur_config_$i:/root/.urnetwork" \
    "$IMAGE" >/dev/null
  log "started $NAME (volume ur_config_$i)"
done

# --- 4. Wait for the first JWT --------------------------------------
log "waiting for urfix-1 to authenticate"
for i in $(seq 1 60); do
  if docker exec urfix-1 test -s /root/.urnetwork/jwt 2>/dev/null; then
    log "authenticated — JWT present"
    break
  fi
  sleep 2
done

log "done. status:"
docker ps --filter "name=urfix-" --format "{{.Names}}\t{{.Status}}"
docker logs urfix-1 --tail 15 2>/dev/null || true