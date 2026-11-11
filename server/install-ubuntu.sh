#!/usr/bin/env bash
# Prepare a clean Ubuntu server (22.04 or 24.04 or later) for the workshop: Docker Engine with the compose
# plugin (from Docker's own repository), git and curl. Run it once, as a user with sudo:
#
#   bash server/install-ubuntu.sh
#
# Then log out and back in (so your account may use Docker without sudo), and continue with SERVER.md.
set -euo pipefail

if ! grep -qi ubuntu /etc/os-release; then
    echo "This script is for Ubuntu. On another system, install Docker Engine and the compose plugin yourself." >&2
    exit 1
fi

echo "== Packages: git, curl, certificates"
sudo apt-get update
sudo apt-get install -y ca-certificates curl git

echo "== Docker's package repository"
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update

echo "== Docker Engine and the compose plugin"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

echo "== Allow $USER to use Docker"
sudo usermod -aG docker "$USER"

echo
echo "Done: $(docker --version 2>/dev/null || sudo docker --version), $(sudo docker compose version)."
echo "Now log out and log back in, then check with:  docker info >/dev/null && echo ok"
