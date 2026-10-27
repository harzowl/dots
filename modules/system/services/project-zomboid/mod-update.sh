#!/usr/bin/env bash
set -euo pipefail

poll_seconds=1
rcon_timeout=10
dry_run=${DRY_RUN:-0}

backend=""
container=""
unit=""
config=""
console=""
env_file=""
lock_file=""
check_timeout=60

usage() {
  echo "usage: $0 --backend <docker|podman> --container <name> --unit <unit> --config <ini> --console <log> --env <dotenv> --lock <file> --timeout <seconds>" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend) backend=${2:?}; shift 2 ;;
    --container) container=${2:?}; shift 2 ;;
    --unit) unit=${2:?}; shift 2 ;;
    --config) config=${2:?}; shift 2 ;;
    --console) console=${2:?}; shift 2 ;;
    --env) env_file=${2:?}; shift 2 ;;
    --lock) lock_file=${2:?}; shift 2 ;;
    --timeout) check_timeout=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done

log() { printf 'zomboid-mod-update: %s\n' "$*"; }
skip() {
  log "$*"
  exit 0
}

[ -n "$backend" ] && [ -n "$container" ] && [ -n "$unit" ] &&
  [ -n "$config" ] && [ -n "$console" ] && [ -n "$env_file" ] &&
  [ -n "$lock_file" ] || usage

exec 9>"$lock_file"
if ! flock -n 9; then
  skip "another check is already running"
fi

if ! systemctl is-active --quiet "$unit"; then
  skip "container unit $unit is inactive"
fi

if [ ! -r "$env_file" ]; then
  skip "env file $env_file is not readable"
fi

RCON_PASSWORD=$(sed -n 's/^RCON_PASSWORD=//p' "$env_file" | tr -d '\r' | head -n1 || true)

if [ -z "$RCON_PASSWORD" ]; then
  skip "RCON_PASSWORD is missing from $env_file"
fi

if [ ! -r "$config" ]; then
  skip "server config $config is not readable"
fi

port=$(grep -m1 '^RCONPort=' "$config" | cut -d= -f2- || true)
port=${port:-27015}

ip=$("$backend" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null || true)
if [ -z "$ip" ]; then
  skip "could not determine the $container container IP"
fi

rcon() {
  timeout "$rcon_timeout" rcon-cli --host "$ip" --port "$port" --password "$RCON_PASSWORD" "$@"
}

players_count() {
  local out
  out=$(rcon players 2>&1 || true)
  out=$(printf '%s\n' "$out" | sed -r 's/\x1B\[[0-9;]*[mK]//g')
  printf '%s\n' "$out" | grep -oE 'Players connected \([0-9]+\)' | grep -oE '[0-9]+' | head -n1 || true
}

count=$(players_count)
if [ -z "$count" ]; then
  skip "could not read the connected players"
fi
if [ "$count" -gt 0 ]; then
  skip "players online ($count); not checking for updates"
fi

if [ ! -r "$console" ]; then
  skip "server console $console is not readable"
fi

before=$(wc -l <"$console")
rcon checkModsNeedUpdate >/dev/null 2>&1 || true

deadline=$((SECONDS + check_timeout))
result=""
while [ "$SECONDS" -lt "$deadline" ]; do
  result=$(tail -n "+$((before + 1))" "$console" 2>/dev/null |
    grep -E 'CheckModsNeedUpdate: (Mods updated|Mods need update)' |
    tail -n1 || true)
  [ -n "$result" ] && break
  sleep "$poll_seconds"
done

if [ -z "$result" ]; then
  skip "mod check timed out or returned an unknown result"
fi

case "$result" in
  *"Mods updated"*) skip "mods are up to date" ;;
  *"Mods need update"*) log "mods need an update" ;;
  *) skip "mod check returned an unknown result" ;;
esac

if ! rcon save >/dev/null 2>&1; then
  skip "save failed; not restarting"
fi
sleep 1

count=$(players_count)
if [ -z "$count" ]; then
  skip "could not read the connected players after save"
fi
if [ "$count" -gt 0 ]; then
  skip "players online ($count) after save; not restarting"
fi

if [ "$dry_run" = 1 ]; then
  log "would restart $unit (dry run)"
  exit 0
fi

systemctl restart "$unit"
log "restarted $unit"
