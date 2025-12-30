#!/bin/bash
# Audit & Remediation cho Phần 2
# (CIS Apache Cassandra 4.0 Benchmark v1.1.0)
#
# CÁCH DÙNG:
# 1. Chỉ Audit: ./audit_section2.sh
# 2. Audit & Tự động sửa lỗi: sudo ./audit_section2.sh --remediate
#
# LƯU Ý: Chạy với --remediate cần quyền sudo và sẽ thay đổi cấu hình hệ thống.
#        Script này sẽ KHỞI ĐỘNG LẠI dịch vụ Cassandra nếu có sửa lỗi.
#

# --- Cấu hình Biến ---
REMEDIATE=0
LOG_FILE="/var/log/cis_cassandra_audit_section2.log"

CASSANDRA_CONFIG_FILE="/etc/cassandra/cassandra.yaml" 

BACKUP_DIR="/var/backups/cis_cassandra"
NEED_RESTART=0 # Cờ để check nếu Cassandra cần restart

# Biến đếm lỗi
AUDIT_FAILED_COUNT=0

# --- Màu sắc cho Log ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m' # Màu mới cho output lệnh
NC='\033[0m' # No Color

# --- Hàm Ghi log ---
# $1: Cấp độ (INFO, PASS, FAIL, REMEDIATE, CMD)
# $2: Thông điệp
# $3: (Optional) suppress_stdout - If set to 1, don't print to screen
log() {
    local level=$1
    local message=$2
    local suppress_stdout=${3:-0}
    local color=$NC

    case $level in
        PASS) color=$GREEN ;;
        FAIL) color=$RED; [[ $suppress_stdout -eq 0 ]] && ((AUDIT_FAILED_COUNT++)) ;; # Only count fails printed to screen
        INFO) color=$BLUE ;;
        REMEDIATE) color=$YELLOW ;;
        CMD) color=$CYAN ;;
    esac

    # Ghi ra file log với timestamp
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
    # In ra màn hình với màu sắc (trừ khi bị chặn)
    if [[ $suppress_stdout -eq 0 ]]; then
        echo -e "[${color}${level}${NC}] $message"
    fi
}

# --- Hàm chạy lệnh, log, và hiển thị output ---
# $@: Lệnh cần chạy (bao gồm cả sudo nếu cần)
run_cmd() {
    local cmd_string="$*"
    local output
    local exit_code

    log "CMD" "Executing: $cmd_string"

    # Chạy lệnh và bắt cả stdout/stderr vào biến 'output'
    output=$(eval "$cmd_string" 2>&1)
    exit_code=$?

    # Ghi output đầy đủ vào file log (không in ra màn hình ở bước này)
    if [[ -n "$output" ]]; then
        while IFS= read -r line; do
             log "CMD_OUT" "$line" 1 # Suppress stdout for log lines
        done <<< "$output"
        echo "--------------------" >> "$LOG_FILE"
    fi

    # In output ra màn hình với màu khác
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
# $1: File cần backup
backup() {
    if [ ! -f "$1" ]; then
        log "INFO" "Không tìm thấy file $1 để backup."
        return 0 # Không coi đây là lỗi
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

# $1: Tên key (ví dụ: authenticator)
# $2: Giá trị mong muốn (ví dụ: PasswordAuthenticator)
# $3: Giá trị không mong muốn (ví dụ: AllowAllAuthenticator)
# $4: ID của mục kiểm tra (ví dụ: 2.1)
# $5: Tên của mục kiểm tra (ví dụ: Authentication)
audit_and_remediate_yaml_key() {
    local key_name="$1"
    local desired_value="$2"
    local undesired_value="$3"
    local check_id="$4"
    local check_name="$5"
    local check_failed=0
    local current_value=""

    log "INFO" "$check_id Bắt đầu kiểm tra: $check_name ($key_name)"

    if [ ! -f "$CASSANDRA_CONFIG_FILE" ]; then
        log "FAIL" "$check_id Không tìm thấy file cấu hình: $CASSANDRA_CONFIG_FILE"
        return
    fi

    # Bước 1: Đọc giá trị
    # Dùng grep với pattern chính xác: Bắt đầu bằng key, theo sau là dấu hai chấm
    # Điều này tránh khớp nhầm các dòng comment
    current_value=$(grep -E "^$key_name:" "$CASSANDRA_CONFIG_FILE" | tail -n 1 | awk '{print $2}')
    
    # Nếu grep không tìm thấy gì (ví dụ: key bị comment), $current_value sẽ rỗng
    if [ -z "$current_value" ]; then
        # Thử tìm xem nó có bị comment không
        if grep -qE "^\s*#\s*$key_name:" "$CASSANDRA_CONFIG_FILE"; then
            log "FAIL" "$check_id $check_name đang bị vô hiệu hóa (commented out)."
            check_failed=1
        else
            log "FAIL" "$check_id $check_name không được tìm thấy hoặc có giá trị rỗng."
            check_failed=1
        fi
    elif [[ "$current_value" == "$desired_value" ]]; then
        log "PASS" "$check_id $check_name đã được bật ($desired_value)."
    elif [[ "$current_value" == "$undesired_value" ]]; then
        log "FAIL" "$check_id $check_name đang bị tắt (giá trị hiện tại: '$current_value')."
        check_failed=1
    else
        log "FAIL" "$check_id $check_name đang có giá trị không mong muốn: '$current_value'."
        check_failed=1
    fi

    # Bước 2: Sửa lỗi (nếu cần)
    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "$check_id Đang đặt '$key_name' thành '$desired_value'..."
        backup "$CASSANDRA_CONFIG_FILE" || return

        local cmd_success=0
        
        # Tạo pattern sed chính xác:
        # 1. Tìm dòng bắt đầu bằng 0 hoặc nhiều dấu cách (cho trường hợp thụt lề)
        # 2. Có thể có dấu # hoặc không
        # 3. Theo sau là tên key và dấu hai chấm
        # 4. Thay thế toàn bộ dòng
        local sed_pattern="s/^\s*#?\s*$key_name:.*/$key_name: $desired_value/"
        
        # Kiểm tra xem key có tồn tại (dù bị comment hay không)
        if grep -qE "^\s*#?\s*$key_name:" "$CASSANDRA_CONFIG_FILE"; then
            run_cmd "sudo sed -i -E \"$sed_pattern\" \"$CASSANDRA_CONFIG_FILE\"" && cmd_success=1
        else
            # Nếu key hoàn toàn không tồn tại, thêm nó vào cuối file
            log "REMEDIATE" "$check_id Key '$key_name' không tồn tại, đang thêm vào cuối file..."
            run_cmd "echo '$key_name: $desired_value' | sudo tee -a \"$CASSANDRA_CONFIG_FILE\"" && cmd_success=1
        fi
        
        if [ $cmd_success -eq 1 ]; then
            log "INFO" "$check_id Đã sửa file config, đánh dấu cần restart Cassandra."
            NEED_RESTART=1
            
            # Kiểm tra lại
            local new_value
            new_value=$(grep -E "^$key_name:" "$CASSANDRA_CONFIG_FILE" | awk '{print $2}')

            if [[ "$new_value" == "$desired_value" ]]; then
                log "PASS" "$check_id REMEDIATED: File cấu hình đã được cập nhật thành công."
                ((AUDIT_FAILED_COUNT--))
            else
                log "FAIL" "$check_id REMEDIATION FAILED: Ghi file thất bại (giá trị sau khi sửa: '$new_value')."
            fi
        else
            log "FAIL" "$check_id REMEDIATION FAILED: Lỗi khi thực thi lệnh sed/tee."
        fi
    fi
}

# --- Hàm Bọc (Wrapper) ---
# Hàm bọc cho mục 2.1
audit_2_1() {
    audit_and_remediate_yaml_key \
        "authenticator" \
        "PasswordAuthenticator" \
        "AllowAllAuthenticator" \
        "2.1" \
        "Authentication"
}

# Hàm bọc cho mục 2.2
audit_2_2() {
    audit_and_remediate_yaml_key \
        "authorizer" \
        "CassandraAuthorizer" \
        "AllowAllAuthorizer" \
        "2.2" \
        "Authorization"
}
# --- HẾT HÀM BỌC ---


#--- Hàm Chính
main() {
    # Kiểm tra và thiết lập file log
    if ! sudo touch "$LOG_FILE" 2>/dev/null; then
         echo -e "${RED}[FAIL]${NC} Không thể ghi vào file log $LOG_FILE. Kiểm tra quyền hoặc chạy với sudo."
         exit 1
    fi
    # Đặt quyền ghi cho user hiện tại để hàm log có thể ghi
    if ! sudo chown "$(logname):$(id -g -n "$(logname)")" "$LOG_FILE"; then
         echo -e "${YELLOW}[WARN]${NC} Không thể thay đổi chủ sở hữu file log. Log có thể cần quyền sudo để ghi."
    fi
    # Xóa nội dung file log cũ một cách an toàn
    truncate -s 0 "$LOG_FILE"

    # Reset biến đếm lỗi và cờ restart
    AUDIT_FAILED_COUNT=0
    NEED_RESTART=0

    log "INFO" "====================================================================="
    log "INFO" "BẮT ĐẦU AUDIT PHẦN 2 (Authentication and Authorization)"
    log "INFO" "Remediation mode: $REMEDIATE (1=On, 0=Off)"
    log "INFO" "Log file: $LOG_FILE"
    log "INFO" "====================================================================="
    
    echo "" # Thêm dòng trống

    # Gọi các hàm bọc
    audit_2_1
    audit_2_2

    # Xử lý khởi động lại dịch vụ
    if [ $NEED_RESTART -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "INFO" "====================================================================="
        log "REMEDIATE" "Phát hiện thay đổi cấu hình, đang khởi động lại Cassandra..."
        run_cmd "sudo systemctl restart cassandra" && {
            log "INFO" "Chờ 10 giây cho Cassandra khởi động..."
            sleep 10
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
    log "INFO" "KẾT THÚC AUDIT PHẦN 2"

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
# Parse cờ (flags) trước
while [[ $# -gt 0 ]]; do
    case $1 in
        --remediate) REMEDIATE=1 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

# Kiểm tra quyền root nếu bật --remediate
if [ $REMEDIATE -eq 1 ] && [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[FAIL]${NC} Vui lòng chạy với 'sudo' khi sử dụng cờ --remediate."
  exit 1
fi

main
exit $? # Lấy exit code từ hàm main
