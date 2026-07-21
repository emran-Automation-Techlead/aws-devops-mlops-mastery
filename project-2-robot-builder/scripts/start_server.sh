#!/bin/bash
# ApplicationStart hook - starts the app under pm2, which restarts it
# automatically if it crashes and keeps it running across SSH sessions.
set -euo pipefail

echo "==> Starting robot-builder-app with pm2"
cd /home/ec2-user/app/app
sudo -u ec2-user env PORT=3000 pm2 start server.js --name robot-builder-app
sudo -u ec2-user pm2 save
