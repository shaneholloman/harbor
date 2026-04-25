#!/bin/sh
# Prepare the agent key file. If HARBOR_BESZEL_AGENT_KEY is set (the user has
# pasted the hub's SSH public key via `harbor config set beszel.agent.key ...`),
# write it as-is. Otherwise generate a throwaway ed25519 placeholder so the
# agent binary — which refuses to start without a parseable key — can boot,
# listen on its port, and idle while rejecting connections from any hub.
set -e

KEY_DIR="/agent_data"
KEY_FILE="${KEY_DIR}/key.pub"

mkdir -p "${KEY_DIR}"

if [ -n "${HARBOR_BESZEL_AGENT_KEY}" ]; then
  printf '%s\n' "${HARBOR_BESZEL_AGENT_KEY}" > "${KEY_FILE}"
  echo "[harbor-beszel-agent-init] using user-provided key from HARBOR_BESZEL_AGENT_KEY"
  exit 0
fi

if [ ! -s "${KEY_FILE}" ] || ! grep -q '^ssh-' "${KEY_FILE}"; then
  apk add --no-cache openssh-keygen >/dev/null 2>&1 || true
  ssh-keygen -t ed25519 -N "" -f "${KEY_DIR}/placeholder_key" -C "harbor-beszel-placeholder" -q
  cp "${KEY_DIR}/placeholder_key.pub" "${KEY_FILE}"
  rm -f "${KEY_DIR}/placeholder_key" "${KEY_DIR}/placeholder_key.pub"
  echo "[harbor-beszel-agent-init] HARBOR_BESZEL_AGENT_KEY is empty; wrote a placeholder"
  echo "[harbor-beszel-agent-init] open the hub, create admin, click Add System,"
  echo "[harbor-beszel-agent-init] then: harbor config set beszel.agent.key '<key>' && harbor restart beszel-agent"
fi
