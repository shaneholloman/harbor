#!/bin/bash

# These configs will be added by
# respective parts of Harbor stack, we want to merge
# everything into one file and launch the server
echo "Harbor: custom aider entrypoint"
python --version

echo "YAML Merger is starting..."
python /home/appuser/.aider/yaml_config_merger.py --pattern ".yml" --output "/home/appuser/.aider.conf.yml" --directory "/home/appuser/.aider"

# Aider searches for .aider.conf.yml in $HOME, which is /app in this image, not
# /home/appuser. Mirror the merged config there so it's auto-discovered.
if [ -n "$HOME" ] && [ "$HOME" != "/home/appuser" ]; then
    cp /home/appuser/.aider.conf.yml "$HOME/.aider.conf.yml"
fi

echo "Merged Configs:"
cat /home/appuser/.aider.conf.yml

git config --global --add safe.directory /root/workspace

echo "Starting aider with args: '$*'"
aider "$@"
