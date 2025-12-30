#!/bin/bash
# configure_cassandra.sh — Cấu hình N-node cluster (linh hoạt)
# Mục tiêu: Các node join cluster → nodetool status thấy tất cả

set -e
sudo rm -rf /var/lib/cassandra/data/*

# === Thay đổi: Chấp nhận 2 tham số ===
NODE_IP=$1
SEED_LIST=$2
CONFIG="/etc/cassandra/cassandra.yaml"

# === Thay đổi: Kiểm tra cả 2 tham số ===
if [ -z "$NODE_IP" ] || [ -z "$SEED_LIST" ]; then
    echo "Usage:   $0 <MY_NODE_IP> \"<SEED_LIST_COMMA_SEPARATED>\""
    echo "Example: $0 192.168.28.146 \"192.168.28.146,192.168.28.145\""
    exit 1
fi

[ ! -f "$CONFIG" ] && { echo "Không tìm thấy $CONFIG"; exit 1; }

echo "==> [1] Backup cấu hình gốc"
sudo mkdir -p /root/cassandra-backup
sudo cp $CONFIG /root/cassandra-backup/cassandra.yaml.bak.$(date +%s)

echo "==> [2] Cấu hình cơ bản cho node $NODE_IP"

# === CÁC THIẾT LẬP CƠ BẢN ===
# Dùng sed để tìm và thay thế các dòng
sudo sed -i \
    -e "s/^cluster_name:.*/cluster_name: 'TestCluster'/" \
    -e "s/^listen_address:.*/listen_address: $NODE_IP/" \
    -e "s/^rpc_address:.*/rpc_address: $NODE_IP/" \
    -e "s/^endpoint_snitch:.*/endpoint_snitch: GossipingPropertyFileSnitch/" \
    $CONFIG

echo "==> [3] Cấu hình seeds: $SEED_LIST"
sudo sed -i "s/^\( * - seeds: \).*/\1\"$SEED_LIST\"/" $CONFIG

echo "==> [4] Khởi động lại Cassandra"
sudo systemctl restart cassandra

echo "==> [5] Đợi 70 giây để node join cluster..."
sleep 70

echo "==> [6] Kiểm tra trạng thái cluster"
nodetool status

echo "==> HOÀN TẤT! Nếu thấy các node 'UN' → thành công!"
