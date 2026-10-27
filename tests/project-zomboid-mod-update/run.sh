#!/usr/bin/env bash
# Behavioural tests for the Project Zomboid mod-update checker.
# Mocks docker, rcon-cli and systemctl; uses the real flock/timeout/sed/grep.
set -uo pipefail

script=${1:-}
if [ -z "$script" ]; then
  echo "usage: $0 <mod-update.sh>" >&2
  exit 2
fi
if [ ! -f "$script" ]; then
  echo "FAIL: missing script: $script" >&2
  exit 1
fi

tmp=$(mktemp -d)
bash_path=$(command -v bash)
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
state="$tmp/state"
mkdir -p "$bin" "$state"
export MOCK_STATE="$state"
export MOCK_CONSOLE="$tmp/server-console.txt"
export PATH="$bin:$PATH"

cat >"$bin/rcon-cli" <<'MOCK'
#!/usr/bin/env bash
state=${MOCK_STATE:?}
printf '%s\n' "$*" >>"$state/rcon.calls"
cmd=${!#}
case "$cmd" in
  players)
    n=0
    [ -f "$state/players.n" ] && n=$(cat "$state/players.n")
    n=$((n + 1))
    printf '%s\n' "$n" >"$state/players.n"
    if [ "$n" -eq 1 ]; then
      printf '%s\n' "${MOCK_PLAYERS_FIRST:-}"
    else
      printf '%s\n' "${MOCK_PLAYERS_SECOND:-${MOCK_PLAYERS_FIRST:-}}"
    fi
    ;;
  save)
    exit "${MOCK_SAVE_RC:-0}"
    ;;
  checkModsNeedUpdate)
    if [ -n "${MOCK_CHECK_RESULT:-}" ]; then
      printf 'LOG : Mod    f:0 CheckModsNeedUpdate: %s\n' "$MOCK_CHECK_RESULT" >>"$MOCK_CONSOLE"
    fi
    ;;
esac
exit 0
MOCK

cat >"$bin/docker" <<'MOCK'
#!/usr/bin/env bash
state=${MOCK_STATE:?}
printf '%s\n' "$*" >>"$state/docker.calls"
if [ "${1:-}" = inspect ]; then
  printf '%s\n' "${MOCK_IP:-}"
fi
exit 0
MOCK

cat >"$bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
state=${MOCK_STATE:?}
printf '%s\n' "$*" >>"$state/systemctl.calls"
case "${1:-}" in
  is-active)
    if [ "${MOCK_UNIT_ACTIVE:-1}" = 1 ]; then exit 0; else exit 1; fi
    ;;
  restart)
    exit 0
    ;;
esac
exit 0
MOCK

for mock in rcon-cli docker systemctl; do
  sed -i "1c#!$bash_path" "$bin/$mock"
done
chmod +x "$bin/rcon-cli" "$bin/docker" "$bin/systemctl"

pass=0
fail=0

check() {
  local desc=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    echo "FAIL $desc" >&2
    fail=$((fail + 1))
  fi
}

reset() {
  rm -rf "$state"
  mkdir -p "$state"
  printf 'RCON_PASSWORD=dummy-DO-NOT-USE-rcon-password\n' >"$tmp/rcon.env"
  printf 'RCONPort=27015\n' >"$tmp/server.ini"
  : >"$tmp/server-console.txt"
  rm -f "$tmp/lock"
  unset MOCK_PLAYERS_FIRST MOCK_PLAYERS_SECOND MOCK_CHECK_RESULT MOCK_SAVE_RC MOCK_UNIT_ACTIVE MOCK_IP DRY_RUN
  export MOCK_UNIT_ACTIVE=1
  export MOCK_IP=192.0.2.10
  export MOCK_CHECK_RESULT='Mods need update'
  export MOCK_PLAYERS_FIRST='Players connected (0):'
  export MOCK_PLAYERS_SECOND='Players connected (0):'
  export MOCK_SAVE_RC=0
}

run() {
  bash "$script" \
    --backend docker \
    --container zomboid \
    --unit docker-zomboid.service \
    --config "$tmp/server.ini" \
    --console "$tmp/server-console.txt" \
    --env "$tmp/rcon.env" \
    --lock "$tmp/lock" \
    --timeout "${CASE_TIMEOUT:-2}" >"$tmp/out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "--- script output ---" >&2; sed -n "1,40p" "$tmp/out" >&2; fi
}

has_restart() { grep -q '^restart ' "$state/systemctl.calls" 2>/dev/null; }
no_restart() { ! has_restart; }
has_save() { grep -q ' save$' "$state/rcon.calls" 2>/dev/null; }
no_save() { ! has_save; }
has_players() { grep -q ' players$' "$state/rcon.calls" 2>/dev/null; }
no_players() { ! has_players; }
has_check() { grep -q ' checkModsNeedUpdate$' "$state/rcon.calls" 2>/dev/null; }
no_rcon() { [ ! -s "$state/rcon.calls" ]; }
out_has() { grep -qi -- "$1" "$tmp/out"; }
rc_zero() { [ "$rc" -eq 0 ]; }
players_count() { grep -c ' players$' "$state/rcon.calls" 2>/dev/null; }
check_order() {
  local check_line players_line
  check_line=$(grep -n ' checkModsNeedUpdate$' "$state/rcon.calls" | cut -d: -f1 | head -n1)
  players_line=$(grep -n ' players$' "$state/rcon.calls" | cut -d: -f1 | head -n1)
  [ -n "$check_line" ] && [ -n "$players_line" ] && [ "$check_line" -lt "$players_line" ]
}

# S1: mods need update, one player online -> no save, no restart.
reset
export MOCK_PLAYERS_FIRST=$'\033[1;32mPlayers connected (1):\033[0m'
run
check "S1 exits 0" rc_zero
check "S1 checks mods" has_check
check "S1 checks players" has_players
check "S1 does not save" no_save
check "S1 does not restart" no_restart
check "S1 reports players online" out_has 'players online'

# S2: mods are current -> stop before the player query.
reset
export MOCK_CHECK_RESULT='Mods updated'
run
check "S2 exits 0" rc_zero
check "S2 does not query players" no_players
check "S2 does not save" no_save
check "S2 does not restart" no_restart
check "S2 reports up to date" out_has 'up to date'

# S3: mods need update, no players -> save, recheck, restart.
reset
run
check "S3 exits 0" rc_zero
check "S3 saves" has_save
check "S3 restarts" has_restart
check "S3 queries players twice" test "$(players_count)" -eq 2
check "S3 checks mods before players" check_order
check "S3 reports restart" out_has 'restart'

# S4: a player joins after the save -> no restart.
reset
export MOCK_PLAYERS_FIRST='Players connected (0):'
export MOCK_PLAYERS_SECOND='Players connected (1):'
run
check "S4 exits 0" rc_zero
check "S4 saves" has_save
check "S4 does not restart" no_restart
check "S4 reports the join" out_has 'players online'

# S5a: no check result -> no save, no restart.
reset
export MOCK_CHECK_RESULT=''
CASE_TIMEOUT=1
run
check "S5a exits 0" rc_zero
check "S5a does not save" no_save
check "S5a does not restart" no_restart
check "S5a reports timeout" out_has 'timed out\|unknown'

# S5b: unreadable player answer -> no save, no restart.
reset
export MOCK_PLAYERS_FIRST='garbage'
run
check "S5b exits 0" rc_zero
check "S5b does not save" no_save
check "S5b does not restart" no_restart
check "S5b reports unknown players" out_has 'could not read the connected players'

# S6: container unit inactive -> nothing runs.
reset
export MOCK_UNIT_ACTIVE=0
run
check "S6 exits 0" rc_zero
check "S6 makes no RCON calls" no_rcon
check "S6 does not restart" no_restart
check "S6 reports inactive" out_has 'inactive'

# S7: missing RCON_PASSWORD -> nothing runs.
reset
printf 'ADMIN_PASSWORD=dummy-DO-NOT-USE-admin-password\n' >"$tmp/rcon.env"
run
check "S7 exits 0" rc_zero
check "S7 makes no RCON calls" no_rcon
check "S7 does not restart" no_restart
check "S7 reports the secret" out_has 'RCON_PASSWORD'

# S8: DRY_RUN still saves but never restarts.
reset
export DRY_RUN=1
run
check "S8 exits 0" rc_zero
check "S8 saves" has_save
check "S8 does not restart" no_restart
check "S8 reports would restart" out_has 'would restart'

# S9: no container IP -> nothing runs.
reset
export MOCK_IP=''
run
check "S9 exits 0" rc_zero
check "S9 makes no RCON calls" no_rcon
check "S9 does not restart" no_restart
check "S9 reports the IP" out_has 'IP'

# S10: another run holds the lock -> nothing runs.
reset
(
  flock -n 9 || exit 1
  sleep 5
) 9>"$tmp/lock" &
holder=$!
sleep 0.2
run
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
check "S10 exits 0" rc_zero
check "S10 makes no RCON calls" no_rcon
check "S10 does not restart" no_restart
check "S10 reports overlap" out_has 'already running\|another check'

# S11: save failure aborts the restart.
reset
export MOCK_SAVE_RC=1
run
check "S11 exits 0" rc_zero
check "S11 does not restart" no_restart
check "S11 reports save failure" out_has 'save failed'

# S12: missing RCONPort -> 27015 fallback.
reset
printf '\n' >"$tmp/server.ini"
export MOCK_CHECK_RESULT='Mods updated'
run
check "S12 exits 0" rc_zero
check "S12 uses port 27015" grep -q -- '--port 27015' "$state/rcon.calls"
check "S12 does not restart" no_restart

# S13: a password with shell metacharacters is preserved literally.
reset
printf 'RCON_PASSWORD=dummy-DO-NOT-USE-$dollar space\n' >"$tmp/rcon.env"
export MOCK_CHECK_RESULT='Mods updated'
run
check "S13 exits 0" rc_zero
check "S13 preserves the literal password" grep -F -q -- '--password dummy-DO-NOT-USE-$dollar space' "$state/rcon.calls"
check "S13 does not restart" no_restart

echo "$pass/$((pass + fail)) passed"
[ "$fail" -eq 0 ]
