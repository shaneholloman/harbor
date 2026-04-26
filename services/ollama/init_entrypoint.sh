#!/usr/bin/env bash

set -eo pipefail

echo "Harbor: ollama init"

main() {
  pull_default_models
  # Marker is read by the healthcheck; tail keeps the sidecar in running|healthy
  # so `compose --wait` doesn't flag a clean exit as premature failure.
  mkdir -p /run/harbor && touch /run/harbor/ollama-init-done
  exec tail -f /dev/null
}

pull_default_models() {
  echo "Pulling default models:"
  echo $HARBOR_OLLAMA_DEFAULT_MODELS

  # We're in "ollama-init", but actual ollama runs
  # in the "ollama" container, so we need to point the CLI
  export OLLAMA_HOST=http://ollama:11434

  if [ -z "$HARBOR_OLLAMA_DEFAULT_MODELS" ]; then
    echo "No default models to pull"
    return
  fi

  echo "Pulling default models"
  IFS=',' read -ra models <<< "$HARBOR_OLLAMA_DEFAULT_MODELS"
  for model in "${models[@]}"; do
    echo "Pulling model $model"
    ollama pull $model
  done
}

main