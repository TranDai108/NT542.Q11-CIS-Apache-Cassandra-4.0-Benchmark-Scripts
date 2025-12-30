#!/bin/bash
# audit_remediate_section3.sh - Audit & Remediation cho Phần 3: Access Control / Password Policies
# (CIS Apache Cassandra 4.0 Benchmark v1.1.0)
#
# CÁCH DÙNG:
# 1. Chỉ Audit: ./audit_section3.sh
# 2. Audit & Tự động sửa lỗi: sudo ./audit_section3.sh --remediate
#
# LƯU Ý: Chạy với --remediate cần quyền sudo và sẽ thay đổi cấu hình hệ thống.
#        Một số mục sẽ yêu cầu KHỞI ĐỘNG LẠI dịch vụ Cassandra.
#

# --- Cấu hình Biến ---
REMEDIATE=0
LOG_FILE="/var/log/cis_cassandra_audit_section3.log"

CASSANDRA_CONFIG_FILE="/etc/cassandra/cassandra.yaml" 
CASSANDRA_SERVICE_FILE="/etc/systemd/system/cassandra.service" # Dùng cho mục 3.4
CQLSH_CMD="/usr/bin/cqlsh"

#Please define the new password in here
CASSANDRA_NEW_PASSWORD="<NEWPASSWORD>" 
LOCALIP=$(hostname -I | awk '{print $1}') # Tự động lấy IP đầu tiên của máy hiện tại (làm động)
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

# --- Hàm chạy lệnh, log, và hiển thị output ---
run_cmd() {
    local cmd_string="$*"
    local output
    local exit_code

    log "CMD" "Executing: $cmd_string"
    output=$(set -o pipefail; eval "$cmd_string" 2>&1)
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

# --- HÀM HELPER CHO VIỆC SỬA FILE YAML ---
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

    current_value=$(grep -E "^$key_name:" "$CASSANDRA_CONFIG_FILE" | tail -n 1 | awk '{print $2}')
    
    if [ -z "$current_value" ]; then
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

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "$check_id Đang đặt '$key_name' thành '$desired_value'..."
        backup "$CASSANDRA_CONFIG_FILE" || return

        local cmd_success=0
        local sed_pattern="s/^\s*#?\s*$key_name:.*/$key_name: $desired_value/"

        if grep -qE "^\s*#?\s*$key_name:" "$CASSANDRA_CONFIG_FILE"; then
            run_cmd "sudo sed -i -E \"$sed_pattern\" \"$CASSANDRA_CONFIG_FILE\"" && cmd_success=1
        else
            log "REMEDIATE" "$check_id Key '$key_name' không tồn tại, đang thêm vào cuối file..."
            run_cmd "echo '$key_name: $desired_value' | sudo tee -a \"$CASSANDRA_CONFIG_FILE\"" && cmd_success=1
        fi
        
        if [ $cmd_success -eq 1 ]; then
            log "INFO" "$check_id Đã sửa file config, đánh dấu cần restart Cassandra."
            NEED_RESTART=1
            
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

# --- 3.1: Ensure the cassandra and superuser roles are separate (Automated) ---
audit_3_1() {
    log "INFO" "3.1 Bắt đầu kiểm tra: Vai trò 'cassandra' không phải là superuser"
    local check_failed=0
    
    local superuser_list
    superuser_list=$(sudo cqlsh "$LOCALIP" -u cassandra -p cassandra -e "SELECT role FROM system_auth.roles WHERE is_superuser = true ALLOW FILTERING;" 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log "WARN" "3.1 Không thể chạy cqlsh. Có thể do lỗi kết nối hoặc authentication đã được bật. Bỏ qua..."
        return
    fi

    if echo "$superuser_list" | grep -q "cassandra"; then
        log "FAIL" "3.1 Vai trò 'cassandra' vẫn đang là superuser. Nên lưu ý tạo một role super user mới phù hợp"
        check_failed=1
    else
        log "PASS" "3.1 Vai trò 'cassandra' không phải là superuser."
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "3.1 Đang tước quyền superuser của vai trò 'cassandra'..."
        run_cmd "sudo cqlsh "$LOCALIP" -u cassandra -p cassandra -e \"UPDATE system_auth.roles SET is_superuser=false WHERE role='cassandra';\"" && {
            log "PASS" "3.1 REMEDIATED: Đã tước quyền superuser của 'cassandra'. (Không cần restart)"
            ((AUDIT_FAILED_COUNT--))
        } || log "FAIL" "3.1 REMEDIATION FAILED: Lỗi khi chạy lệnh cqlsh."
    fi
}

# --- 3.2: Ensure that the default password is changed for the cassandra role (Automated) ---
audit_3_2() {
    log "INFO" "3.2 Bắt đầu kiểm tra: Mật khẩu mặc định của 'cassandra'"
    local check_failed=0
    
    # Thử login với user/pass mặc định
    sudo cqlsh "$LOCALIP" -u cassandra -p cassandra -e "exit" >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        log "FAIL" "3.2 Đăng nhập thành công với 'cassandra:cassandra'. Mật khẩu mặc định chưa được đổi."
        check_failed=1
    else
        log "PASS" "3.2 Không thể đăng nhập với 'cassandra:cassandra'. Mật khẩu mặc định đã được đổi."
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        if [ -z "$CASSANDRA_NEW_PASSWORD" ]; then
            log "WARN" "3.2 REMEDIATION BỎ QUA (THỦ CÔNG): Biến CASSANDRA_NEW_PASSWORD chưa được đặt trong script. Vui lòng đặt mật khẩu và chạy lại."
            # Không giảm count, vì lỗi vẫn còn
        else
            log "REMEDIATE" "3.2 Đang đổi mật khẩu của 'cassandra' thành mật khẩu quy định..."
            local cql_query="ALTER ROLE 'cassandra' WITH PASSWORD = '$CASSANDRA_NEW_PASSWORD';"
            run_cmd "sudo cqlsh "$LOCALIP" -u Admin -p admin -e \"$cql_query\"" && {
                log "PASS" "3.2 REMEDIATED: Đã đổi mật khẩu mặc định thành công."
                ((AUDIT_FAILED_COUNT--))
            } || log "FAIL" "3.2 REMEDIATION FAILED: Lỗi khi chạy lệnh cqlsh. (Lưu ý: Nếu Section 2 đã chạy, script này có thể thất bại)"
        fi
    fi
}

# --- 3.4: Ensure that Cassandra is run using a non-privileged, dedicated service account (Automated) ---
audit_3_4() {
    log "INFO" "3.4 Bắt đầu kiểm tra: User chạy dịch vụ Cassandra (Tương tự 1.5)"
    local process_user
    process_user=$(ps -eo user:20,pid,ppid,cmd:100 | grep "[j]ava.*cassandra" | awk '{print $1}')
    local check_failed=0

    if [ -z "$process_user" ]; then
        log "INFO" "3.4 Dịch vụ Cassandra dường như không chạy. Bỏ qua kiểm tra."
        return
    fi

    if [[ "$process_user" == "cassandra" ]]; then
        log "PASS" "3.4 Dịch vụ Cassandra đang chạy với user 'cassandra'."
    else
        log "FAIL" "3.4 Dịch vụ Cassandra đang chạy với user '$process_user' (phải là 'cassandra')."
        check_failed=1
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        if [ -f "$CASSANDRA_SERVICE_FILE" ]; then
            log "REMEDIATE" "3.4 Đang cấu hình $CASSANDRA_SERVICE_FILE để chạy với user/group 'cassandra'..."
            backup "$CASSANDRA_SERVICE_FILE" || return

            {
                run_cmd "sudo sed -i 's/^User=.*/User=cassandra/' \"$CASSANDRA_SERVICE_FILE\"" && \
                run_cmd "sudo sed -i 's/^Group=.*/Group=cassandra/' \"$CASSANDRA_SERVICE_FILE\"" && \
                run_cmd "sudo systemctl daemon-reload" && \
                run_cmd "sudo systemctl restart cassandra"
            } && {
                log "INFO" "3.4 Chờ Cassandra khởi động lại..."
                sleep 5
                local new_user
                new_user=$(ps -aef | grep "[j]ava.*cassandra" | awk '{print $1}')
                if [[ "$new_user" == "cassandra" ]]; then
                    log "PASS" "3.4 REMEDIATED: Dịch vụ đã khởi động lại với user 'cassandra'."
                    NEED_RESTART=0
                    ((AUDIT_FAILED_COUNT--))
                else
                    log "FAIL" "3.4 REMEDIATION FAILED: Dịch vụ vẫn chạy với user '$new_user' sau khi restart."
                    NEED_RESTART=1
                fi
            } || {
                log "FAIL" "3.4 REMEDIATION FAILED: Lỗi khi sửa file service hoặc restart Cassandra."
                NEED_RESTART=1
            }
        else
            log "FAIL" "3.4 REMEDIATION FAILED: Không tìm thấy file service tại $CASSANDRA_SERVICE_FILE. Cần sửa thủ công."
        fi
    fi
}

# --- [THÊM MỚI] 3.5: Ensure that Cassandra only listens on authorized interfaces (Manual) ---
audit_3_5() {
    log "INFO" "3.5 Bắt đầu kiểm tra: Listen address không được là 0.0.0.0 (Manual)"
    local check_failed=0
    
    if [ ! -f "$CASSANDRA_CONFIG_FILE" ]; then
        log "FAIL" "3.5 Không tìm thấy file cấu hình: $CASSANDRA_CONFIG_FILE"
        return
    fi

    # Đọc giá trị, chỉ các dòng đang hoạt động (không comment)
    local listen_addr
    listen_addr=$(grep -E "^listen_address:" "$CASSANDRA_CONFIG_FILE" | tail -n 1 | awk '{print $2}')
    
    local listen_if
    listen_if=$(grep -E "^listen_interface:" "$CASSANDRA_CONFIG_FILE" | tail -n 1 | awk '{print $2}')

    if [[ "$listen_addr" == "0.0.0.0" ]]; then
        log "FAIL" "3.5 'listen_address' đang được đặt là '0.0.0.0'. Đây là một rủi ro bảo mật nghiêm trọng."
        check_failed=1
    elif [[ "$listen_if" == "0.0.0.0" ]]; then
        log "FAIL" "3.5 'listen_interface' đang được đặt là '0.0.0.0'. Đây là một rủi ro bảo mật nghiêm trọng."
        check_failed=1
    else
        log "PASS" "3.5 Không phát hiện listen_address/listen_interface nào được đặt là '0.0.0.0'."
        log "INFO" "3.5 (Giá trị hiện tại: listen_address='${listen_addr:-chưa đặt}', listen_interface='${listen_if:-chưa đặt}')"
    fi

    # Xử lý "Remediation" (chỉ cảnh báo)
    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "WARN" "3.5 REMEDIATION CẦN LÀM THỦ CÔNG. Script sẽ không tự động sửa."
        log "WARN" "     -> Hướng dẫn: Mở file $CASSANDRA_CONFIG_FILE, tìm 'listen_address' hoặc 'listen_interface'."
        log "WARN" "     -> Đặt 'listen_address' thành địa chỉ IP riêng của node này (ví dụ: 192.168.1.10)."
        log "WARN" "     -> KHÔNG được đặt là 0.0.0.0. (Tham khảo CIS Benchmark mục 3.5)"
        # Lỗi vẫn được đếm, không giảm AUDIT_FAILED_COUNT
    fi
}

# --- 3.6: Ensure that Data Center Authorizations is activated (Manual/Automated) ---
audit_3_6() {
    # Benchmark đánh dấu (Manual) nhưng các bước audit/remediate có thể tự động
    audit_and_remediate_yaml_key \
        "network_authorizer" \
        "CassandraNetworkAuthorizer" \
        "AllowAllNetworkAuthorizer" \
        "3.6" \
        "Data Center Authorization"
}

#--- Hàm Chính
main() {
    # Kiểm tra và thiết lập file log
    if ! sudo touch "$LOG_FILE" 2>/dev/null; then
         echo -e "${RED}[FAIL]${NC} Không thể ghi vào file log $LOG_FILE. Kiểm tra quyền hoặc chạy với sudo."
         exit 1
    fi
    if ! sudo chown "$(logname):$(id -g -n "$(logname)")" "$LOG_FILE"; then
         echo -e "${YELLOW}[WARN]${NC} Không thể thay đổi chủ sở hữu file log. Log có thể cần quyền sudo để ghi."
    fi
    truncate -s 0 "$LOG_FILE"

    log "INFO" "============================================= ========================"
    log "INFO" "BẮT ĐẦU AUDIT PHẦN 3 (Access Control / Password Policies)"
    log "INFO" "Remediation mode: $REMEDIATE (1=On, 0=Off)"
    log "INFO" "Log file: $LOG_FILE"
    log "INFO" "============================================= ========================"
    
    echo "" # Thêm dòng trống

    # Gọi các hàm kiểm tra
    audit_3_1
    audit_3_2
    audit_3_4
    audit_3_5  
    audit_3_6
    
    # Xử lý khởi động lại dịch vụ
    if [ $NEED_RESTART -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "INFO" "=========================================== ========================="
        log "REMEDIATE" "Phát hiện thay đổi cấu hình (3.4 hoặc 3.6), đang khởi động lại Cassandra..."
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
        log "INFO" "=========================================== ========================="
        log "WARN" "Các thay đổi cấu hình đã được ghi nhận, nhưng remediation đang tắt. Cần khởi động lại Cassandra thủ công (sudo systemctl restart cassandra) để áp dụng."
    fi

    log "INFO" "============================================= ========================"
    log "INFO" "KẾT THÚC AUDIT PHẦN 3"

    local final_fail_count=$AUDIT_FAILED_COUNT

    if [ $final_fail_count -eq 0 ]; then
        log "PASS" "TỔNG KẾT: Tất cả các mục kiểm tra đều PASS."
    else
        log "FAIL" "TỔNG KẾT: Có $final_fail_count mục kiểm tra bị FAIL."
    fi
    log "INFO" "============================================= ========================"

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
