#!/bin/bash
# install_cassandra.sh — Cài đặt Apache Cassandra 4.0 theo CIS Benchmark v1.1.0

set -e

echo "==> [1] Cập nhật hệ thống và cài Java"
sudo apt update -y
sudo apt install -y openjdk-11-jdk apt-transport-https curl gnupg lsb-release chrony

echo "==> [2] Tạo user/group riêng cho Cassandra (PASS 1.1)"
sudo groupadd cassandra 2>/dev/null || true
sudo useradd -g cassandra -d /var/lib/cassandra -s /bin/bash cassandra 2>/dev/null || true
sudo mkdir -p /var/lib/cassandra /var/log/cassandra
sudo chown -R cassandra:cassandra /var/lib/cassandra /var/log/cassandra

echo "==> [3] Thêm repository Cassandra 4.0 và import key"
curl -sSL https://downloads.apache.org/cassandra/KEYS | sudo gpg --dearmor -o /usr/share/keyrings/cassandra-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cassandra-archive-keyring.gpg] https://debian.cassandra.apache.org 41x main" | sudo tee /etc/apt/sources.list.d/cassandra.list

echo "==> [4] Cài đặt Cassandra 4.0.x mới nhất (PASS 1.4)"
sudo apt update -y
sudo apt install -y cassandra

echo "==> [5] Bật NTP để đồng bộ clock (PASS 1.6)"
sudo systemctl enable --now chrony

echo "==> [6] Enable dịch vụ để chuẩn bị cấu hình"
sudo systemctl enable cassandra
sudo systemctl start cassandra

echo "==> Cài đặt Cassandra hoàn tất"
sudo systemctl status cassandra --no-pager
echo "Version: $(cassandra -v)"
