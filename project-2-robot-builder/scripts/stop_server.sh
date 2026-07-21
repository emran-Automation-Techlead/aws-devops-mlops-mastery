#!/bin/bash
# ApplicationStop hook - runs BEFORE the new revision's files are copied
# down, and ALSO runs on an instance that has never had a deployment
# before (the very first deploy). Must not fail just because nothing is
# running yet.
set -euo pipefail

if command -v pm2 >/dev/null 2>&1 && sudo -u ec2-user pm2 describe robot-builder-app >/dev/null 2>&1; then
  echo "==> Stopping existing robot-builder-app process"
  sudo -u ec2-user pm2 delete robot-builder-app
else
  echo "==> No existing process found (first deploy) - nothing to stop"
fi
