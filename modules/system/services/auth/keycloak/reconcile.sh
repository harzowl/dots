#!/usr/bin/env bash
# Reconcile the Keycloak realm against the generated (partial-import) JSON.
#
# Runs on every activation that changes that JSON. It waits for Keycloak to be
# reachable (the first boot's implicit build can take many minutes), resolves
# the ${VAR} client secrets from the secretspec env file, and upserts the realm
# roles and clients through the Admin API. `--import-realm` still seeds the
# realm on first boot; this keeps later edits (redirect URIs, roles, secrets)
# in sync.
set -euo pipefail

PORT="@PORT@"
REALM="@REALM@"
ADMIN="@ADMIN_USER@"
PARTIAL="@PARTIAL_JSON@"
ENV_FILE="@ENV_FILE@"
CONTAINER="@CONTAINER@"

for _ in $(seq 1 240); do
  curl -fsS "http://127.0.0.1:${PORT}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1 && break
  sleep 5
done

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

resolved="$(mktemp)"
envsubst < "${PARTIAL}" > "${resolved}"
docker cp "${resolved}" "${CONTAINER}:/tmp/partial.json"

kcadm() { docker exec "${CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"; }

kcadm config credentials \
  --server "http://127.0.0.1:${PORT}" --realm master \
  --user "${ADMIN}" --password "${KC_BOOTSTRAP_ADMIN_PASSWORD}"

kcadm create partialImport -r "${REALM}" -f /tmp/partial.json
