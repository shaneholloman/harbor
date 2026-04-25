#!/bin/sh
# Prepare the agent key file. If HARBOR_BESZEL_AGENT_KEY is set (the user has
# pasted the hub's SSH public key via `harbor config set beszel.agent.key ...`),
# validate it parses then write it. Otherwise generate a throwaway ed25519
# placeholder so the agent binary — which refuses to start without a parseable
# key — can boot, listen on its port, and idle while rejecting connections
# from any hub.
set -e

KEY_DIR="/agent_data"
KEY_FILE="${KEY_DIR}/key.pub"
TMP_KEY="${KEY_DIR}/.key.candidate"

mkdir -p "${KEY_DIR}"

# ssh-keygen is needed both for generating the placeholder and for validating
# user-provided keys. Install once up front.
if ! apk add --no-cache openssh-keygen >/dev/null 2>&1; then
  echo "[harbor-beszel-agent-init] FATAL: failed to install openssh-keygen (no network?)" >&2
  exit 1
fi

# Files written by this container land on the host bind mount. Chown them to
# the host user so the user can `rm` / inspect them without `sudo`. Called
# from a trap so it fires on every exit path (success, validation failure,
# placeholder write).
chown_workspace() {
  if [ -n "${HARBOR_USER_ID}" ] && [ -n "${HARBOR_GROUP_ID}" ]; then
    chown -R "${HARBOR_USER_ID}:${HARBOR_GROUP_ID}" "${KEY_DIR}" 2>/dev/null || true
    # The hub's data dir is also bind-mounted here only so we can chown it
    # before the host-user-owned hub container starts. Docker creates missing
    # bind-mount targets as root on first launch, which would otherwise lock
    # the hub out of its own data dir.
    if [ -d /beszel_data ]; then
      chown -R "${HARBOR_USER_ID}:${HARBOR_GROUP_ID}" /beszel_data 2>/dev/null || true
    fi
  fi
}
trap chown_workspace EXIT

is_valid_pubkey() {
  # ssh-keygen -l accepts private keys too; reject those explicitly.
  if grep -q 'BEGIN [A-Z]* PRIVATE KEY' "$1"; then
    return 1
  fi
  ssh-keygen -l -f "$1" >/dev/null 2>&1
}

write_placeholder() {
  ssh-keygen -t ed25519 -N "" -f "${KEY_DIR}/placeholder_key" -C "harbor-beszel-placeholder" -q
  cp "${KEY_DIR}/placeholder_key.pub" "${KEY_FILE}"
  rm -f "${KEY_DIR}/placeholder_key" "${KEY_DIR}/placeholder_key.pub"
  echo "[harbor-beszel-agent-init] HARBOR_BESZEL_AGENT_KEY is empty; wrote a placeholder"
  echo "[harbor-beszel-agent-init] open the hub, create admin, click Add System,"
  echo "[harbor-beszel-agent-init] then: harbor config set beszel.agent.key '<key>' && harbor restart beszel"
}

if [ -n "${HARBOR_BESZEL_AGENT_KEY}" ]; then
  # Validate the user-provided key BEFORE overwriting the existing key file.
  # This makes the failure surface here, in the init container's logs, with a
  # clear hint — instead of as an opaque agent crash loop.
  printf '%s\n' "${HARBOR_BESZEL_AGENT_KEY}" > "${TMP_KEY}"
  if ! is_valid_pubkey "${TMP_KEY}"; then
    rm -f "${TMP_KEY}"
    echo "[harbor-beszel-agent-init] ERROR: HARBOR_BESZEL_AGENT_KEY is set but does not parse as a valid SSH public key." >&2
    echo "[harbor-beszel-agent-init] Paste only the 'ssh-ed25519 AAAA... comment' line shown by the hub's Add System dialog." >&2
    echo "[harbor-beszel-agent-init] To clear it: harbor config set beszel.agent.key '' && harbor restart beszel" >&2
    exit 1
  fi
  mv "${TMP_KEY}" "${KEY_FILE}"
  echo "[harbor-beszel-agent-init] using user-provided key from HARBOR_BESZEL_AGENT_KEY"
  exit 0
fi

# No user key set. Keep an existing key only if it actually parses; a stale
# bad value (e.g. previously-pasted typo) must be replaced, not preserved.
if [ -s "${KEY_FILE}" ] && is_valid_pubkey "${KEY_FILE}"; then
  echo "[harbor-beszel-agent-init] preserving existing valid key at ${KEY_FILE}"
  exit 0
fi

write_placeholder
