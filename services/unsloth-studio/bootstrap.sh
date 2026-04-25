#!/bin/sh
# Post-Studio sidecar: turns the manual "log in, change password, create API
# key, paste into HARBOR_UNSLOTH_STUDIO_API_KEY" sequence into a one-shot
# zero-click bootstrap.
#
# Studio's auth surface (verified live):
#   1. Bootstrap creds are inlined in the SPA HTML as
#      window.__UNSLOTH_BOOTSTRAP__={"username":"unsloth","password":"<words>"}
#      until the user completes first-run setup.
#   2. POST /api/auth/login with those creds returns a JWT and
#      must_change_password=true.
#   3. POST /api/auth/change-password with the JWT clears the flag and
#      returns a fresh JWT.
#   4. POST /api/auth/api-keys mints a long-lived bearer key (sk-unsloth-...)
#      that other Harbor services consume via HARBOR_UNSLOTH_STUDIO_API_KEY.
#
# Studio's auth.db lives in the container (no bind mount), so it resets on
# every container recreate. The script handles this by always testing the
# stored key first — if it works, exit fast (idempotent); if it 401s the
# DB has been wiped and we re-run the full flow with a fresh bootstrap pw.
set -e

ENV_FILE="/harbor_env"
KEY_VAR="HARBOR_UNSLOTH_STUDIO_API_KEY"
KEY_PLACEHOLDER="sk-unsloth-studio"
STUDIO_URL="${STUDIO_URL:-http://unsloth-studio:8000}"

# Files written by this container land on bind mounts; chown them on every
# exit path so the host user can edit/delete .env without sudo.
chown_workspace() {
  if [ -n "${HARBOR_USER_ID}" ] && [ -n "${HARBOR_GROUP_ID}" ]; then
    chown "${HARBOR_USER_ID}:${HARBOR_GROUP_ID}" "${ENV_FILE}" 2>/dev/null || true
  fi
}
trap chown_workspace EXIT

if ! apk add --no-cache curl jq >/dev/null 2>&1; then
  echo "[unsloth-studio-bootstrap] FATAL: failed to install curl + jq (no network?)" >&2
  exit 1
fi

# Read current value of HARBOR_UNSLOTH_STUDIO_API_KEY from .env.
current_key() {
  grep -E "^${KEY_VAR}=" "${ENV_FILE}" 2>/dev/null | head -1 | sed -E "s/^${KEY_VAR}=\"?([^\"]*)\"?$/\1/"
}

# Replace HARBOR_UNSLOTH_STUDIO_API_KEY=... in-place. sed -i would error
# with "Resource busy" because .env is bind-mounted as a single file (the
# atomic rename crosses inodes). Render to a tmp file then `cat >` back to
# preserve the original inode that Docker has bound.
write_key() {
  new_key="$1"
  esc_key=$(printf '%s' "${new_key}" | sed 's/[\/&]/\\&/g')
  tmp=$(mktemp -t harbor.XXXXXX)
  sed -E "s|^${KEY_VAR}=.*$|${KEY_VAR}=\"${esc_key}\"|" "${ENV_FILE}" > "${tmp}"
  cat "${tmp}" > "${ENV_FILE}"
  rm -f "${tmp}"
}

echo "[unsloth-studio-bootstrap] waiting for Studio at ${STUDIO_URL}..."
if ! curl -sS --retry 30 --retry-delay 2 --retry-all-errors "${STUDIO_URL}/api/health" >/dev/null; then
  echo "[unsloth-studio-bootstrap] FATAL: Studio not reachable after 60s" >&2
  exit 1
fi

# Step 1: decide whether to run.
#   - Empty / placeholder → first-run bootstrap.
#   - Anything else → respect it (could be a user-set key from the Studio
#     UI, a long-lived JWT, or our own previous bootstrap). If it's our
#     bootstrap output and it 200s, exit fast (idempotent). If it 401s
#     and the prefix matches our minted-key shape (sk-unsloth-<32 hex>),
#     re-bootstrap because Studio's auth.db must have been wiped. Any
#     other value is treated as a manual override and left alone.
KEY=$(current_key)
case "${KEY}" in
  '' | "${KEY_PLACEHOLDER}")
    echo "[unsloth-studio-bootstrap] no key set — running first-run bootstrap"
    ;;
  sk-unsloth-????????????????????????????????)
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${KEY}" \
      "${STUDIO_URL}/v1/models" || true)
    if [ "${status}" = "200" ]; then
      echo "[unsloth-studio-bootstrap] existing API key still valid — skipping"
      exit 0
    fi
    echo "[unsloth-studio-bootstrap] stored key returned HTTP ${status}; re-bootstrapping (Studio DB likely reset)"
    ;;
  *)
    echo "[unsloth-studio-bootstrap] manual override detected (${KEY_VAR} not in sk-unsloth-* shape) — leaving it alone"
    exit 0
    ;;
esac

# Step 2: scrape the bootstrap creds from the served HTML.
HTML=$(curl -sS "${STUDIO_URL}/")
BOOTSTRAP_JSON=$(printf '%s' "${HTML}" | grep -oE '__UNSLOTH_BOOTSTRAP__=\{[^<]*\}' | head -1 | sed 's/^__UNSLOTH_BOOTSTRAP__=//')
if [ -z "${BOOTSTRAP_JSON}" ]; then
  echo "[unsloth-studio-bootstrap] FATAL: __UNSLOTH_BOOTSTRAP__ literal not found in served HTML" >&2
  exit 1
fi
USERNAME=$(printf '%s' "${BOOTSTRAP_JSON}" | jq -r '.username')
BOOTSTRAP_PW=$(printf '%s' "${BOOTSTRAP_JSON}" | jq -r '.password')
if [ -z "${USERNAME}" ] || [ -z "${BOOTSTRAP_PW}" ] || [ "${USERNAME}" = "null" ] || [ "${BOOTSTRAP_PW}" = "null" ]; then
  echo "[unsloth-studio-bootstrap] FATAL: failed to parse bootstrap creds" >&2
  exit 1
fi

# Step 3: log in with the bootstrap creds.
LOGIN_RESP=$(curl -sS -X POST "${STUDIO_URL}/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u "${USERNAME}" --arg p "${BOOTSTRAP_PW}" '{username:$u, password:$p}')")
JWT=$(printf '%s' "${LOGIN_RESP}" | jq -r '.access_token // empty')
if [ -z "${JWT}" ]; then
  echo "[unsloth-studio-bootstrap] FATAL: login failed: ${LOGIN_RESP}" >&2
  exit 1
fi

# Step 4: change the password. Studio rejects /api/auth/api-keys until
# must_change_password is cleared. We pick a fresh random password each
# run; nobody needs to read it back (the API key is the persistent handle).
NEW_PW="harbor-bootstrap-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | dd bs=1 count=24 2>/dev/null)"
CHANGE_RESP=$(curl -sS -X POST "${STUDIO_URL}/api/auth/change-password" \
  -H "Authorization: Bearer ${JWT}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg c "${BOOTSTRAP_PW}" --arg n "${NEW_PW}" '{current_password:$c, new_password:$n}')")
JWT=$(printf '%s' "${CHANGE_RESP}" | jq -r '.access_token // empty')
if [ -z "${JWT}" ]; then
  echo "[unsloth-studio-bootstrap] FATAL: change-password failed: ${CHANGE_RESP}" >&2
  exit 1
fi

# Step 5: mint an API key.
KEY_RESP=$(curl -sS -X POST "${STUDIO_URL}/api/auth/api-keys" \
  -H "Authorization: Bearer ${JWT}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"harbor-bootstrap"}')
NEW_KEY=$(printf '%s' "${KEY_RESP}" | jq -r '.key // empty')
if [ -z "${NEW_KEY}" ]; then
  echo "[unsloth-studio-bootstrap] FATAL: api-key creation failed: ${KEY_RESP}" >&2
  exit 1
fi

# Step 6: persist the key into .env so cross-integration compose files
# (webui, boost, aider) substitute it on their next compose-up.
write_key "${NEW_KEY}"
echo "[unsloth-studio-bootstrap] wrote ${KEY_VAR} (prefix: $(printf '%s' "${NEW_KEY}" | cut -c1-12)...) to .env"
echo "[unsloth-studio-bootstrap] zero-click bootstrap complete"
