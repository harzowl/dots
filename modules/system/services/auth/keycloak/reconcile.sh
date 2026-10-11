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
PROFILE="@PROFILE_JSON@"

if ! curl -fsS "http://127.0.0.1:${PORT}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
  echo "Keycloak not ready on :${PORT}; the timer will retry."
kcadm update "realms/${REALM}" @SMTP_UPDATE@

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

# The declarative user profile: not part of partialImport, and its `${...}` are
# Keycloak i18n keys — do NOT envsubst it.
if [ -n "${PROFILE}" ]; then
  docker exec -i "${CONTAINER}" sh -c 'cat > /tmp/profile.json' < "${PROFILE}" || exit 0
  kcadm update users/profile -r "${REALM}" -f /tmp/profile.json || true
fi

# Authoritative: `realm-admin` is held by exactly the declared users — grant the
# declared, revoke anyone else — so removing a name actually removes the role.
declared_admins="@REALM_ADMINS@"
for u in $(kcadm get users -r "${REALM}" --fields username --format csv 2>/dev/null | tr -d '"\r'); do
  if kcadm get-roles -r "${REALM}" --uusername "$u" --cclientid realm-management 2>/dev/null | grep -q realm-admin; then
    has=yes
  else
    has=no
  fi
  case " ${declared_admins} " in
    *" ${u} "*)
      [ "${has}" = yes ] || kcadm add-roles -r "${REALM}" --uusername "$u" --cclientid realm-management --rolename realm-admin || true
      ;;
    *)
      [ "${has}" = no ] || kcadm remove-roles -r "${REALM}" --uusername "$u" --cclientid realm-management --rolename realm-admin || true
      ;;
  esac
done

# Authoritative: a required action is a default exactly when it is declared, so
# removing one from the list turns it back off too.
declared_actions="@DEFAULT_REQUIRED_ACTIONS@"
for a in $(kcadm get authentication/required-actions -r "${REALM}" --fields alias --format csv 2>/dev/null | tr -d '"\r'); do
  case " ${declared_actions} " in
    *" ${a} "*) on=true ;;
    *) on=false ;;
  esac
  kcadm update "authentication/required-actions/${a}" -r "${REALM}" -s defaultAction="${on}" || true
done

exit 0
