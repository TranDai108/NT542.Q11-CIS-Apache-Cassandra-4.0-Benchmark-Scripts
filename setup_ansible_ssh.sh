#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" -eq 0 ]; then
  echo "Không chạy script bằng sudo. Hãy chạy bằng user thường."
  exit 1
fi

# Sửa user và IP cho phù hợp
REMOTE_USER="<USER>"

NODE_IPS=(
  "192.168.100.10"
  "192.168.100.20"
  "192.168.100.30"
)

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
SSH_KEY_COMMENT="ansible_key"

# Cài Ansible và sshpass
sudo apt update -y
sudo apt install -y ansible sshpass

# Tạo SSH key nếu chưa có
if [ ! -f "$SSH_KEY_PATH" ]; then
  ssh-keygen -t ed25519 -C "$SSH_KEY_COMMENT" -f "$SSH_KEY_PATH" -N ""
fi

# Copy key sang các node
for ip in "${NODE_IPS[@]}"; do
  ssh-copy-id -i "${SSH_KEY_PATH}.pub" "$REMOTE_USER@$ip"
done
