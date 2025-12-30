#!/bin/bash
# audit_remediate_section5.sh - Audit & Remediation cho Phần 5: Encryption
# (CIS Apache Cassandra 4.0/4.1 Benchmark style)
#
# YÊU CẦU:
# 1. Có 'yq' (script sẽ tự cài nếu thiếu).
# 2. ĐÃ TẠO keystore/truststore cho từng node (theo scripts generate_node_cert / build_truststore).
#
# CÁCH DÙNG:
#   - Chỉ audit:
#         ./audit_remediate_section5.sh
#   - Audit + tự động sửa:
#         sudo ./audit_remediate_section5.sh --remediate
#

# --- Biến chính ---
REMEDIATE=0
LOG_FILE="/var/log/cis_cassandra_audit_section5.log"

CASSANDRA_CONFIG_FILE="/etc/cassandra/cassandra.yaml"
NODETOOL_CMD="nodetool"
BACKUP_DIR="/var/backups/cis_cassandra"
NEED_RESTART=0
AUDIT_FAILED_COUNT=0

# --- TLS CONFIG ---
TLS_DIR="/etc/cassandra"
TLS_KEYSTORE_PASSWORD="cassandra"
TLS_TRUSTSTORE_PASSWORD="cassandra"

# node1.keystore, node2.keystore, node3.keystore ...
NODE_NAME=$(hostname -s)
NODE_KEYSTORE="$TLS_DIR/${NODE_NAME}.keystore"
NODE_TRUSTSTORE="$TLS_DIR/cassandra.truststore"

# --- Màu sắc ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- Hàm log ---
log() {
    local level=$1
    local message=$2
    local suppress_stdout=${3:-0}
    local color=$NC

    case $level in
        PASS) color=$GREEN ;;
        FAIL) color=$RED; [[ $suppress_stdout -eq 0 ]] && ((AUDIT_FAILED_COUNT++)) ;;
        WARN|REMEDIATE) color=$YELLOW ;;
        INFO) color=$BLUE ;;
        CMD|CMD_OUT) color=$CYAN ;;
        *) color=$NC ;;
    esac

    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
    if [[ $suppress_stdout -eq 0 ]]; then
        echo -e "[${color}${level}${NC}] $message"
    fi
}

# --- Hàm chạy lệnh ---
run_cmd() {
    local cmd_string="$*"
    local output
    local exit_code

    log "CMD" "Executing: $cmd_string"
    output=$(eval "$cmd_string" 2>&1)
    exit_code=$?

    if [[ -n "$output" ]]; then
        while IFS= read -r line; do
            log "CMD_OUT" "$line" 1
        done <<< "$output"
        echo "--------------------" >> "$LOG_FILE"
    fi

    if [[ -n "$output" ]]; then
        echo -e "${MAGENTA}--- Command Output Start ---${NC}"
        while IFS= read -r line; do
            echo -e "${MAGENTA}| ${NC}$line"
        done <<< "$output"
        echo -e "${MAGENTA}--- Command Output End ---${NC}"
    fi

    if [ $exit_code -eq 0 ]; then
        log "INFO" "Command succeeded."
        return 0
    else
        log "FAIL" "Command failed with exit code $exit_code. Output đã ghi vào log."
        return $exit_code
    fi
}

# --- Hàm backup file config ---
backup() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log "INFO" "Không tìm thấy file $file để backup."
        return 0
    fi

    if [ $REMEDIATE -eq 1 ]; then
        if [ ! -d "$BACKUP_DIR" ]; then
            log "INFO" "Tạo thư mục backup: $BACKUP_DIR"
            run_cmd "sudo mkdir -p \"$BACKUP_DIR\"" || {
                REMEDIATE=0
                log "FAIL" "Backup failed: Không tạo được thư mục backup."
                return 1
            }
        fi

        local backup_path="$BACKUP_DIR/$(basename "$file").$(date +%s).bak"
        log "INFO" "Backing up $file -> $backup_path"
        run_cmd "sudo cp \"$file\" \"$backup_path\"" || {
            REMEDIATE=0
            log "FAIL" "Backup failed: Không copy được file config."
            return 1
        }
    fi
    return 0
}

# --- Kiểm tra dependency (yq, nodetool) ---
check_dependencies() {
    if ! command -v $NODETOOL_CMD &> /dev/null; then
        log "WARN" "Không tìm thấy '$NODETOOL_CMD' trong PATH. Một số check runtime có thể bị bỏ qua."
    fi

    if ! command -v yq &> /dev/null; then
        log "WARN" "Chưa có 'yq'. Đang tải binary yq..."
        
        local ARCH
        ARCH=$(dpkg --print-architecture)
        local YQ_BINARY=""

        if [[ "$ARCH" == "amd64" ]]; then
            YQ_BINARY="yq_linux_amd64"
        elif [[ "$ARCH" == "arm64" ]]; then
            YQ_BINARY="yq_linux_arm64"
        else
            log "FAIL" "Kiến trúc '$ARCH' không hỗ trợ auto-install yq. Cài thủ công."
            return 1
        fi

        if run_cmd "sudo wget -qO /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/$YQ_BINARY && sudo chmod +x /usr/bin/yq"; then
            log "INFO" "Cài yq thành công tại /usr/bin/yq."
        else
            log "FAIL" "Cài yq thất bại. Kiểm tra kết nối mạng."
            return 1
        fi
    fi
    return 0
}

# --- Kiểm tra tồn tại keystore/truststore ---
validate_tls_files() {
    local failed=0

    if [ ! -f "$NODE_KEYSTORE" ]; then
        log "FAIL" "Không tìm thấy keystore: $NODE_KEYSTORE"
        failed=1
    fi

    if [ ! -f "$NODE_TRUSTSTORE" ]; then
        log "FAIL" "Không tìm thấy truststore: $NODE_TRUSTSTORE"
        failed=1
    fi

    if [ $failed -eq 1 ]; then
        log "WARN" "Keystore/Truststore chưa đầy đủ. Nếu bật TLS, Cassandra có thể KHÔNG khởi động được!"
    else
        log "PASS" "Đã tìm thấy keystore & truststore."
    fi

    return $failed
}

# ==============================================================================
# 5.1: Inter-node Encryption
# ==============================================================================
audit_5_1() {
    log "INFO" "---------------------------"
    log "INFO" "5.1: Kiểm tra Inter-node Encryption (server_encryption_options)"
    log "INFO" "---------------------------"

    local check_failed=0
    
    if [ ! -f "$CASSANDRA_CONFIG_FILE" ]; then
        log "FAIL" "5.1: Không tìm thấy $CASSANDRA_CONFIG_FILE"
        return
    fi

    local encryption_val
    encryption_val=$(yq '.server_encryption_options.internode_encryption' "$CASSANDRA_CONFIG_FILE")

    if [[ "$encryption_val" == "all" || "$encryption_val" == "dc" || "$encryption_val" == "rack" ]]; then
        log "PASS" "5.1: internode_encryption hiện đang bật (mode: $encryption_val)."
    else
        log "FAIL" "5.1: internode_encryption chưa bật hoặc sai (giá trị: '$encryption_val'). Yêu cầu: all/dc/rack."
        check_failed=1
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "WARN" "5.1: Đang bật inter-node encryption với mode 'all'..."
        backup "$CASSANDRA_CONFIG_FILE" || return

        # Bật encryption giữa các node
        run_cmd "sudo yq -i '.server_encryption_options.internode_encryption = \"all\"' \"$CASSANDRA_CONFIG_FILE\""

        validate_tls_files

        log "REMEDIATE" "5.1: Thiết lập TLS cho server_encryption_options..."

        run_cmd "sudo yq -i '.server_encryption_options.keystore = \"$NODE_KEYSTORE\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.server_encryption_options.keystore_password = \"$TLS_KEYSTORE_PASSWORD\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.server_encryption_options.truststore = \"$NODE_TRUSTSTORE\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.server_encryption_options.truststore_password = \"$TLS_TRUSTSTORE_PASSWORD\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.server_encryption_options.require_client_auth = true' \"$CASSANDRA_CONFIG_FILE\""

        NEED_RESTART=1
        log "PASS" "5.1: REMEDIATED - Đã bật inter-node encryption (all) + cấu hình TLS."

        ((AUDIT_FAILED_COUNT>0)) && ((AUDIT_FAILED_COUNT--))
    fi
}

# ==============================================================================
# 5.2: Client Encryption (Native Transport)
# ==============================================================================
audit_5_2() {
    log "INFO" "---------------------------"
    log "INFO" "5.2: Kiểm tra Client Encryption (client_encryption_options)"
    log "INFO" "---------------------------"

    local check_failed=0
    
    if [ ! -f "$CASSANDRA_CONFIG_FILE" ]; then
        log "FAIL" "5.2: Không tìm thấy $CASSANDRA_CONFIG_FILE"
        return
    fi

    local client_enabled
    local client_optional
    client_enabled=$(yq '.client_encryption_options.enabled' "$CASSANDRA_CONFIG_FILE")
    client_optional=$(yq '.client_encryption_options.optional' "$CASSANDRA_CONFIG_FILE")

    # CIS: yêu cầu bật encryption; thường khuyến nghị enabled=true, optional=false để bắt buộc SSL.
    if [[ "$client_enabled" == "true" && "$client_optional" == "false" ]]; then
        log "PASS" "5.2: Client encryption đang bật bắt buộc (enabled=true, optional=false)."
    elif [[ "$client_enabled" == "true" && "$client_optional" == "true" ]]; then
        log "WARN" "5.2: Client encryption bật nhưng optional=true (cho phép non-SSL). Tùy policy, có thể xem là chưa đủ chặt."
        check_failed=1
    else
        log "FAIL" "5.2: Client encryption chưa đúng (enabled=$client_enabled, optional=$client_optional)."
        check_failed=1
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "WARN" "5.2: Đang thực hiện remediation theo mô hình B (FULL SSL bắt buộc, dùng port SSL riêng 9142)..."
        backup "$CASSANDRA_CONFIG_FILE" || return

        # Bật client encryption bắt buộc
        run_cmd "sudo yq -i '.client_encryption_options.enabled = true' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.client_encryption_options.optional = false' \"$CASSANDRA_CONFIG_FILE\""

        validate_tls_files

        log "REMEDIATE" "5.2: Gán keystore/truststore cho client_encryption_options..."

        run_cmd "sudo yq -i '.client_encryption_options.keystore = \"$NODE_KEYSTORE\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.client_encryption_options.keystore_password = \"$TLS_KEYSTORE_PASSWORD\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.client_encryption_options.truststore = \"$NODE_TRUSTSTORE\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.client_encryption_options.truststore_password = \"$TLS_TRUSTSTORE_PASSWORD\"' \"$CASSANDRA_CONFIG_FILE\""
        run_cmd "sudo yq -i '.client_encryption_options.require_client_auth = false' \"$CASSANDRA_CONFIG_FILE\""

        # MÔ HÌNH B: Bật native_transport_port_ssl = 9142
        log "REMEDIATE" "5.2: Bật native_transport_port_ssl: 9142 (uncomment/ghi lại key)..."
        run_cmd "sudo yq -i '.native_transport_port_ssl = 9142' \"$CASSANDRA_CONFIG_FILE\""

        NEED_RESTART=1
        log "PASS" "5.2: REMEDIATED - Đã bật client encryption bắt buộc + cấu hình TLS + enable native_transport_port_ssl=9142."

        ((AUDIT_FAILED_COUNT>0)) && ((AUDIT_FAILED_COUNT--))
    fi
}

# --- Hàm chính ---
main() {
    if ! sudo touch "$LOG_FILE" 2>/dev/null; then
        echo -e "${RED}[FAIL]${NC} Không thể ghi log $LOG_FILE. Chạy lại với sudo."
        exit 1
    fi

    if ! sudo chown "$(logname):$(id -g -n "$(logname)")" "$LOG_FILE"; then
        echo -e "${YELLOW}[WARN]${NC} Không đổi được owner log file. Có thể cần sudo để xem log."
    fi
    truncate -s 0 "$LOG_FILE"

    AUDIT_FAILED_COUNT=0
    NEED_RESTART=0

    log "INFO" "====================================================================="
    log "INFO" "BẮT ĐẦU AUDIT PHẦN 5 (Encryption)"
    log "INFO" "Remediation mode: $REMEDIATE (1=On, 0=Off)"
    log "INFO" "Node: $NODE_NAME | Keystore: $NODE_KEYSTORE | Truststore: $NODE_TRUSTSTORE"
    log "INFO" "Log file: $LOG_FILE"
    log "INFO" "====================================================================="

    if ! check_dependencies; then
        log "FAIL" "Thiếu dependency (yq hoặc khác). Dừng script."
        exit 1
    fi

    audit_5_1
    audit_5_2

    if [ $NEED_RESTART -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "Có thay đổi cấu hình Encryption. Đang restart Cassandra..."
        log "WARN" "Lưu ý: Nếu TLS file sai, Cassandra có thể KHÔNG restart được."

        if run_cmd "sudo systemctl restart cassandra"; then
            log "INFO" "Chờ 15 giây cho Cassandra khởi động..."
            sleep 15
            if systemctl is-active --quiet cassandra; then
                log "PASS" "Cassandra đã khởi động lại thành công."
            else
                log "FAIL" "Cassandra KHÔNG thể start lại. Kiểm tra /var/log/cassandra/system.log."
            fi
        else
            log "FAIL" "Lệnh 'systemctl restart cassandra' thất bại."
        fi
    elif [ $NEED_RESTART -eq 1 ] && [ $REMEDIATE -eq 0 ]; then
        log "WARN" "Có thay đổi cấu hình, nhưng REMEDIATE=0. Bạn cần tự restart Cassandra."
    fi

    log "INFO" "====================================================================="
    if [ $AUDIT_FAILED_COUNT -eq 0 ]; then
        log "PASS" "TỔNG KẾT: Tất cả các mục kiểm tra đều PASS."
        echo -e "${GREEN}[OK]${NC} Tất cả các mục kiểm tra đều PASS. Xem chi tiết trong $LOG_FILE"
    else
        log "FAIL" "TỔNG KẾT: Có $AUDIT_FAILED_COUNT mục kiểm tra FAIL."
        echo -e "${RED}[FAIL]${NC} Có $AUDIT_FAILED_COUNT mục FAIL. Xem chi tiết trong $LOG_FILE"
    fi
    log "INFO" "====================================================================="
}

# --- Xử lý tham số ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --remediate) REMEDIATE=1 ;;
        *)
            echo "Unknown flag: $1"
            echo "Usage: $0 [--remediate]"
            exit 1
            ;;
    esac
    shift
done

if [ $REMEDIATE -eq 1 ] && [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[FAIL]${NC} Vui lòng chạy với sudo khi dùng --remediate."
    exit 1
fi

main
exit $?
