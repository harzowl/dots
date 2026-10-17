# Mirror every realm user into a local Navidrome account.
#
# ExtAuth on /rest does not auto-provision, so an account must exist before a
# native client can authenticate through the gate. The realm username is used
# exactly as Keycloak spells it (an email stays an email, a bare login stays
# bare); only the local email is derived, and an account that cannot yield a
# valid address is created without one. Re-running never duplicates an account.
set -euo pipefail

container='@CONTAINER@'
keycloak='@KEYCLOAK_URL@'
realm='@REALM@'
client_id='@CLIENT_ID@'
secret_file='@SECRET_FILE@'
secret_key='@SECRET_KEY@'
email_domain='@EMAIL_DOMAIN@'

secret_config="$(mktemp)"
trap 'rm -f "$secret_config"' EXIT
chmod 600 "$secret_config"
if ! sed -n "s/^${secret_key}=//p" "$secret_file" | tr -d '\n' > "$secret_config"; then
  echo "warning: could not read the sync client secret"
  exit 0
fi

token="$(curl -fsS -X POST "${keycloak}/realms/${realm}/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id="${client_id}" \
  --data-urlencode "client_secret@${secret_config}" 2>/dev/null \
  | jq -r '.access_token // empty')" || token=""

if [ -z "$token" ]; then
  echo "warning: could not read the realm user list"
  exit 0
fi

users="$(curl -fsS -H "Authorization: Bearer ${token}" \
  "${keycloak}/admin/realms/${realm}/users?max=5000&briefRepresentation=false" 2>/dev/null)" \
  || {
    echo "warning: could not read the realm user list"
    exit 0
  }

existing="$(docker exec "$container" /app/navidrome user list -n 2>/dev/null | cut -d, -f2)"

while IFS=$'\t' read -r username email; do
  [ -n "$username" ] || continue
  if printf '%s\n' "$existing" | grep -Fqx -- "$username"; then
    continue
  fi

  derived="$(derive_email "$username" "$email" "$email_domain")"
  args="--username $(printf '%q' "$username")"
  if [ -n "$derived" ]; then
    args="${args} --email $(printf '%q' "$derived")"
  fi

  # The CLI prompts on a TTY; feed it via a PTY. The PTY echoes the password,
  # so keep its output off the journal.
  pw="$(head -c 24 /dev/urandom | base64)"
  printf '%s\n%s\n' "$pw" "$pw" | script -qec \
    "docker exec -it $(printf '%q' "$container") /app/navidrome user create ${args} -n" /dev/null >/dev/null 2>&1 \
    && echo "created Navidrome user '${username}' (from Keycloak)" \
    || echo "warning: could not create Navidrome user '${username}'"
done < <(printf '%s' "$users" | jq -r '.[] | [.username, (.email // "")] | @tsv')
