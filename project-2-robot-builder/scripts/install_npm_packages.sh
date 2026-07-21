#!/bin/bash
# AfterInstall hook - runs AFTER CodeDeploy has copied the new revision's
# files to /home/ec2-user/app. Only now does app/package.json actually
# exist on disk, so this is the correct place for npm ci (installing it
# during BeforeInstall would just reinstall the PREVIOUS deployment's
# dependencies, since the new files aren't there yet).
set -euo pipefail

echo "==> Installing app dependencies"
cd /home/ec2-user/app/app
sudo -u ec2-user npm ci --omit=dev
