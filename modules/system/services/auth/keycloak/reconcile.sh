#!/usr/bin/env bash
# Reconcile the Keycloak realm from the generated partial-import JSON.
#
# Best effort, and it must never fail: activation (and therefore a deploy-rs
# rollback) must not hinge on Keycloak, whose first boot builds for minutes. If
# it isn't answering yet, exit 0 and let `keycloak-reconcile.timer` retry later.
set -u

PORT="@PORT@"
REALM="@REALM@"
ADMIN="@ADMIN_USER@"
PARTIAL="@PARTIAL_JSON@"
ENV_FILE="@ENV_FILE@"
CONTAINER="@CONTAINER@"

if ! curl -fsS "http://127.0.0.1:${PORT}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
  echo "Keycloak not ready on :${PORT}; the timer will retry."
  exit 0
fi

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

# Feed the resolved JSON in over stdin so it is owned by the container user; a
# `docker cp` of a mode-0600 temp file is unreadable to kcadm.
envsubst < "${PARTIAL}" | docker exec -i "${CONTAINER}" sh -c 'cat > /tmp/partial.json' || exit 0

kcadm() { docker exec "${CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"; }

kcadm config credentials \
  --server "http://127.0.0.1:${PORT}" --realm master \
  --user "${ADMIN}" --password "${KC_BOOTSTRAP_ADMIN_PASSWORD}" || exit 0

kcadm create partialImport -r "${REALM}" -f /tmp/partial.json || true

exit 0
