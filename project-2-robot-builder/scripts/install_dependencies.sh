#!/bin/bash
# BeforeInstall hook - runs BEFORE CodeDeploy copies the new revision's
# files onto the instance. This is only for runtime setup (Node.js, pm2)
# that doesn't depend on the new app code existing yet. Idempotent: safe
# to run on every deployment, including the very first one.
set -euo pipefail

echo "==> Checking for Node.js 18..."
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v)" != v18* ]]; then
  echo "==> Installing Node.js 18"
  curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
  sudo yum install -y nodejs
fi

echo "==> Checking for pm2 (process manager - keeps the app alive across crashes/reboots)..."
if ! command -v pm2 >/dev/null 2>&1; then
  sudo npm install -g pm2
fi
