#!/bin/bash
# audit_remediate_section4.sh - Audit & Remediation cho Phần 4: Auditing and Logging
# (CIS Apache Cassandra 4.0 Benchmark v1.1.0)
#
# PHIÊN BẢN: Dành cho cài đặt qua APT/DEB (/etc/cassandra)
# YÊU CẦU: Cài đặt 'yq' (sudo apt install yq)
#
# CÁCH DÙNG:
# 1. Chỉ Audit: ./audit_remediate_section4.sh
# 2. Audit & Tự động sửa lỗi: sudo ./audit_remediate_section4.sh --remediate
#

# --- Cấu hình Biến (Đã sửa đường dẫn) ---
REMEDIATE=0
LOG_FILE="/var/log/cis_cassandra_audit_section4.log"

# !!! ĐƯỜNG DẪN CHUẨN CHO APT INSTALL !!!
CASSANDRA_CONFIG_FILE="/etc/cassandra/cassandra.yaml"
LOGBACK_XML_FILE="/etc/cassandra/logback.xml"

# Lệnh nodetool thường nằm trong PATH khi cài qua apt
NODETOOL_CMD="nodetool"
# Hoặc nếu không tìm thấy, thử: NODETOOL_CMD="/usr/bin/nodetool"

BACKUP_DIR="/var/backups/cis_cassandra"
NEED_RESTART=0

# Biến đếm lỗi
AUDIT_FAILED_COUNT=0

# --- Màu sắc cho Log ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- Hàm Ghi log ---
log() {
    local level=$1
    local message=$2
    local suppress_stdout=${3:-0}
    local color=$NC

    case $level in
        PASS) color=$GREEN ;;
        FAIL) color=$RED; [[ $suppress_stdout -eq 0 ]] && ((AUDIT_FAILED_COUNT++)) ;;
        INFO) color=$BLUE ;;
        REMEDIATE) color=$YELLOW ;;
        CMD) color=$CYAN ;;
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
        log "FAIL" "Command failed with exit code $exit_code. Output above and in log file."
        return $exit_code
    fi
}

# --- Hàm Backup ---
backup() {
    if [ ! -f "$1" ]; then
        log "INFO" "Không tìm thấy file $1 để backup."
        return 0
    fi

    if [ $REMEDIATE -eq 1 ]; then
        if [ ! -d "$BACKUP_DIR" ]; then
            log "INFO" "Tạo thư mục backup: $BACKUP_DIR"
            run_cmd "sudo mkdir -p \"$BACKUP_DIR\"" || { REMEDIATE=0; log "FAIL" "Backup failed: Cannot create backup directory."; return 1; }
        fi

        local backup_path="$BACKUP_DIR/$(basename "$1").$(date +%s).bak"
        log "INFO" "Backing up $1 to $backup_path"
        run_cmd "sudo cp \"$1\" \"$backup_path\"" || { REMEDIATE=0; log "FAIL" "Backup failed: Cannot copy file."; return 1; }
    fi
    return 0
}

# --- Hàm kiểm tra Dependencies ---
check_dependencies() {
    local missing=0
    
    # 1. Kiểm tra lệnh nodetool
    if ! command -v $NODETOOL_CMD &> /dev/null; then
        log "WARN" "Không tìm thấy lệnh '$NODETOOL_CMD' trong PATH. Một số check runtime có thể bị bỏ qua."
    fi

    # 2. Kiểm tra yq
    if ! command -v yq &> /dev/null; then
        log "WARN" "Chưa tìm thấy 'yq'. Đang tự động cài đặt (Binary Download)..."
        
        # Phát hiện kiến trúc máy (amd64 hoặc arm64)
        local ARCH
        ARCH=$(dpkg --print-architecture)
        local YQ_BINARY=""

        if [[ "$ARCH" == "amd64" ]]; then
            YQ_BINARY="yq_linux_amd64"
        elif [[ "$ARCH" == "arm64" ]]; then
            YQ_BINARY="yq_linux_arm64"
        else
            log "FAIL" "Kiến trúc máy '$ARCH' không được hỗ trợ tự động. Vui lòng cài yq thủ công."
            return 1
        fi

        # Tải về và cài đặt
        log "INFO" "Phát hiện kiến trúc: $ARCH. Đang tải $YQ_BINARY..."
        
        # Chạy chuỗi lệnh cài đặt
        if run_cmd "sudo wget -qO /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/$YQ_BINARY && sudo chmod +x /usr/bin/yq"; then
            log "INFO" "Đã cài đặt 'yq' thành công tại /usr/bin/yq."
        else
            log "FAIL" "Cài đặt 'yq' thất bại. Vui lòng kiểm tra kết nối mạng."
            return 1
        fi
    fi
    
    return 0
}

# ====================================================================================
# SECTION 4: AUDITING AND LOGGING
# ====================================================================================

# --- 4.1: Ensure that logging is enabled (Automated) ---
audit_4_1() {
    log "INFO" "4.1 Bắt đầu kiểm tra: Logging status (logback.xml)"
    local check_failed=0
    
    # Cách 1: Kiểm tra runtime bằng nodetool (Ưu tiên)
    if command -v $NODETOOL_CMD &> /dev/null; then
        local root_level
        # Lấy log level của ROOT logger
        root_level=$($NODETOOL_CMD getlogginglevels | grep -E "^ROOT" | awk '{print $2}')
        
        if [[ "$root_level" == "OFF" ]]; then
            log "FAIL" "4.1 Logging đang bị tắt (ROOT level = OFF) tại runtime."
            check_failed=1
        elif [[ -n "$root_level" ]]; then
            log "PASS" "4.1 Logging đang được bật tại runtime (ROOT level = $root_level)."
        else
            log "WARN" "4.1 Không thể lấy thông tin logging từ nodetool. Chuyển sang kiểm tra file config."
        fi
    fi

    # Cách 2: Kiểm tra file cấu hình (logback.xml)
    if [ ! -f "$LOGBACK_XML_FILE" ]; then
        log "FAIL" "4.1 Không tìm thấy file logback.xml tại $LOGBACK_XML_FILE"
        return
    fi

    # Tìm dòng <root level="..."> trong XML
    local file_level
    file_level=$(grep -oP '<root level="\K[^"]+' "$LOGBACK_XML_FILE")

    if [[ "$file_level" == "OFF" ]]; then
        log "FAIL" "4.1 Cấu hình trong logback.xml đang tắt logging (level=\"OFF\")."
        check_failed=1
    elif [[ -z "$file_level" ]]; then
         log "WARN" "4.1 Không tìm thấy cấu hình <root level=...> trong logback.xml."
    else
         log "PASS" "4.1 Cấu hình logback.xml hợp lệ (level=\"$file_level\")."
    fi

    # Remediation
    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "4.1 Đang bật logging (Set ROOT level=INFO) trong $LOGBACK_XML_FILE..."
        backup "$LOGBACK_XML_FILE" || return

        # Dùng sed để thay thế
        run_cmd "sudo sed -i 's/<root level=\".*\">/<root level=\"INFO\">/' \"$LOGBACK_XML_FILE\"" && {
            log "INFO" "4.1 Đã sửa file logback.xml. Đánh dấu cần restart."
            NEED_RESTART=1
            
            # Kiểm tra lại
            local new_level
            new_level=$(grep -oP '<root level="\K[^"]+' "$LOGBACK_XML_FILE")
            if [[ "$new_level" == "INFO" ]]; then
                log "PASS" "4.1 REMEDIATED: Logging đã được bật lại (INFO)."
                ((AUDIT_FAILED_COUNT--))
            else
                log "FAIL" "4.1 REMEDIATION FAILED: Sửa file thất bại."
            fi
        } || log "FAIL" "4.1 REMEDIATION FAILED: Lỗi khi chạy lệnh sed."
    fi
}

# --- 4.2: Ensure that auditing is enabled (Manual/Automated) ---
audit_4_2() {
    log "INFO" "4.2 Bắt đầu kiểm tra: Audit Logging (audit_logging_options)"
    local check_failed=0
    
    if [ ! -f "$CASSANDRA_CONFIG_FILE" ]; then
        log "FAIL" "4.2 Không tìm thấy file cấu hình: $CASSANDRA_CONFIG_FILE"
        return
    fi

    # Dùng yq để đọc giá trị nested: audit_logging_options.enabled
    local audit_enabled
    audit_enabled=$(yq '.audit_logging_options.enabled' "$CASSANDRA_CONFIG_FILE")

    if [[ "$audit_enabled" == "true" ]]; then
        log "PASS" "4.2 Audit logging đã được bật (enabled: true)."
    else
        log "FAIL" "4.2 Audit logging đang bị tắt hoặc chưa cấu hình (giá trị: '$audit_enabled')."
        check_failed=1
    fi

    # Remediation
    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "4.2 Đang bật Audit Logging trong $CASSANDRA_CONFIG_FILE..."
        backup "$CASSANDRA_CONFIG_FILE" || return

        # Dùng yq để bật audit logging
        run_cmd "sudo yq -i '.audit_logging_options.enabled = true' \"$CASSANDRA_CONFIG_FILE\"" && {
            log "INFO" "4.2 Đã sửa file config. Đánh dấu cần restart."
            NEED_RESTART=1

            # Kiểm tra lại
            local new_val
            new_val=$(yq '.audit_logging_options.enabled' "$CASSANDRA_CONFIG_FILE")
            if [[ "$new_val" == "true" ]]; then
                log "PASS" "4.2 REMEDIATED: Audit logging đã được bật."
                ((AUDIT_FAILED_COUNT--))
            else
                log "FAIL" "4.2 REMEDIATION FAILED: Ghi file thất bại."
            fi
        } || log "FAIL" "4.2 REMEDIATION FAILED: Lỗi khi chạy lệnh yq."
    fi
}

#--- Hàm Chính
main() {
    if ! sudo touch "$LOG_FILE" 2>/dev/null; then
         echo -e "${RED}[FAIL]${NC} Không thể ghi vào file log $LOG_FILE. Kiểm tra quyền hoặc chạy với sudo."
         exit 1
    fi
    if ! sudo chown "$(logname):$(id -g -n "$(logname)")" "$LOG_FILE"; then
         echo -e "${YELLOW}[WARN]${NC} Không thể thay đổi chủ sở hữu file log. Log có thể cần quyền sudo để ghi."
    fi
    truncate -s 0 "$LOG_FILE"

    AUDIT_FAILED_COUNT=0
    NEED_RESTART=0

    log "INFO" "====================================================================="
    log "INFO" "BẮT ĐẦU AUDIT PHẦN 4 (Auditing and Logging)"
    log "INFO" "Remediation mode: $REMEDIATE (1=On, 0=Off)"
    log "INFO" "Log file: $LOG_FILE"
    log "INFO" "====================================================================="

    if ! check_dependencies; then
        log "FAIL" "Dừng script do thiếu dependency."
        exit 1
    fi
    
    echo "" 

    audit_4_1
    audit_4_2
    
    if [ $NEED_RESTART -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "INFO" "====================================================================="
        log "REMEDIATE" "Phát hiện thay đổi cấu hình Logging/Auditing, đang khởi động lại Cassandra..."
        run_cmd "sudo systemctl restart cassandra" && {
            log "INFO" "Chờ 15 giây cho Cassandra khởi động..."
            sleep 15
            if systemctl is-active --quiet cassandra; then
                log "PASS" "REMEDIATED: Dịch vụ Cassandra đã khởi động lại thành công."
            else
                log "FAIL" "REMEDIATION FAILED: Dịch vụ Cassandra KHÔNG THỂ khởi động lại sau khi thay đổi cấu hình."
                ((AUDIT_FAILED_COUNT++))
            fi
        } || log "FAIL" "REMEDIATION FAILED: Lệnh 'systemctl restart' thất bại."
    elif [ $NEED_RESTART -eq 1 ] && [ $REMEDIATE -eq 0 ]; then
        log "INFO" "====================================================================="
        log "WARN" "Các thay đổi cấu hình đã được ghi nhận, nhưng remediation đang tắt. Cần khởi động lại Cassandra thủ công (sudo systemctl restart cassandra) để áp dụng."
    fi

    log "INFO" "====================================================================="
    log "INFO" "KẾT THÚC AUDIT PHẦN 4"

    local final_fail_count=$AUDIT_FAILED_COUNT

    if [ $final_fail_count -eq 0 ]; then
        log "PASS" "TỔNG KẾT: Tất cả các mục kiểm tra đều PASS."
    else
        log "FAIL" "TỔNG KẾT: Có $final_fail_count mục kiểm tra bị FAIL."
    fi
    log "INFO" "====================================================================="

    if [ $REMEDIATE -eq 1 ]; then
        log "INFO" "Quá trình remediation đã hoàn tất."
    fi

    return $final_fail_count
}

# --- Chạy Script ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --remediate) REMEDIATE=1 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

if [ $REMEDIATE -eq 1 ] && [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[FAIL]${NC} Vui lòng chạy với 'sudo' khi sử dụng cờ --remediate."
  exit 1
fi

main
exit $?
