#!/bin/bash
# audit_remediate_section1.sh — Audit & Remediation cho Phần 1: Installation and Updates (CIS Apache Cassandra 4.0 Benchmark v1.1.0)
#
# CÁCH DÙNG:
# 1. Chỉ Audit: ./audit_remediate_section1.sh
# 2. Audit & Tự động sửa lỗi: sudo ./audit_remediate_section1.sh --remediate
#
# LƯU Ý: Chạy với --remediate cần quyền sudo và sẽ thay đổi cấu hình hệ thống.
#

# --- Cấu hình Biến ---
REMEDIATE=0
LOG_FILE="/var/log/cis_cassandra_audit_section1.log"
CASSANDRA_SERVICE_FILE="/etc/systemd/system/cassandra.service" # Giả định đường dẫn nếu cài qua apt
BACKUP_DIR="/var/backups/cis_cassandra"
MIN_CASSANDRA_VERSION="4.0.13" # Phiên bản tối thiểu yêu cầu

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
        # Ghi từng dòng output vào log để dễ đọc
        while IFS= read -r line; do
             log "CMD_OUT" "$line" 1 # Suppress stdout for log lines
        done <<< "$output"
        # Thêm dòng phân cách vào log file
        echo "--------------------" >> "$LOG_FILE"
    fi

    # In output ra màn hình với màu khác
    if [[ -n "$output" ]]; then
        echo -e "${MAGENTA}--- Command Output Start ---${NC}"
        # In từng dòng output ra màn hình
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

# --- 1.1: Separate user and group for Cassandra (Manual) ---
audit_1_1() {
    log "INFO" "1.1 Bắt đầu kiểm tra: User và group 'cassandra'"
    local check_failed=0
    local fail_reasons=()
    if ! getent group | grep cassandra >/dev/null; then
        fail_reasons+=("Group 'cassandra' không tồn tại.")
        check_failed=1
    fi
    if ! getent passwd | grep cassandra >/dev/null; then
        fail_reasons+=("User 'cassandra' không tồn tại.")
        check_failed=1
    fi

    if [ $check_failed -eq 0 ]; then
         log "PASS" "1.1 User và group 'cassandra' tồn tại."
    else
        # Log tất cả lý do fail một lần
        for reason in "${fail_reasons[@]}"; do
             log "FAIL" "1.1 $reason"
        done

        if [ $REMEDIATE -eq 1 ]; then
            local remediation_ok=1
            if ! getent group cassandra >/dev/null; then
                log "REMEDIATE" "1.1 Đang tạo group 'cassandra'..."
                run_cmd "sudo groupadd cassandra" || remediation_ok=0
            fi
            if ! getent passwd cassandra >/dev/null && [ $remediation_ok -eq 1 ]; then
                log "REMEDIATE" "1.1 Đang tạo user 'cassandra' với shell /bin/bash và home directory..."
                run_cmd "sudo useradd -m -d /home/cassandra -s /bin/bash -g cassandra cassandra" || remediation_ok=0
            fi

            if [ $remediation_ok -eq 1 ] && getent group cassandra >/dev/null && getent passwd cassandra >/dev/null; then
                 log "PASS" "1.1 REMEDIATED: Đã tạo thành công user và group 'cassandra'."
                 # Giảm số lỗi đã tăng trước đó
                 ((AUDIT_FAILED_COUNT-=check_failed)) # Giảm đúng số lỗi đã phát hiện
            else
                 log "FAIL" "1.1 REMEDIATION FAILED: Tạo user/group thất bại."
                 # Không giảm AUDIT_FAILED_COUNT vì vẫn fail
            fi
        fi
    fi
}

# --- 1.2: Latest Java installed (Automated) ---
audit_1_2() {
    log "INFO" "1.2 Bắt đầu kiểm tra: Phiên bản Java"
    local check_failed=0
    local java_version_output=""
    if ! command -v java &> /dev/null; then
        log "FAIL" "1.2 Java chưa được cài đặt."
        check_failed=1
    else
        java_version_output=$(java -version 2>&1)
        if echo "$java_version_output" | grep -q 'version "1.8.0' || echo "$java_version_output" | grep -q 'version "11.0.'; then
            log "PASS" "1.2 Đã cài đặt phiên bản Java tương thích: $(echo "$java_version_output" | head -n 1)"
        else
            log "FAIL" "1.2 Phiên bản Java không tương thích được tìm thấy. Cassandra 4.0 yêu cầu Java 1.8 (ưu tiên) hoặc 11 (thử nghiệm). Tìm thấy: $(echo "$java_version_output" | head -n 1)"
            check_failed=1
        fi
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "1.2 Đang cài đặt openjdk-8-jdk (phiên bản ổn định được khuyến nghị)..."
        run_cmd "sudo apt-get update -y" && \
        run_cmd "sudo apt-get install -y openjdk-8-jdk" && {
            if java -version 2>&1 | grep -q 'version "1.8.0'; then
                log "PASS" "1.2 REMEDIATED: Đã cài đặt thành công openjdk-8-jdk."
                ((AUDIT_FAILED_COUNT--)) # Giảm lỗi nếu thành công
            else
                log "FAIL" "1.2 REMEDIATION FAILED: Cài đặt Java thất bại hoặc phiên bản không đúng sau khi cài."
            fi
        } || log "FAIL" "1.2 REMEDIATION FAILED: Lỗi trong quá trình update/install Java."
    fi
}

# --- 1.3: Latest Python installed (Automated) ---
audit_1_3() {
    log "INFO" "1.3 Bắt đầu kiểm tra: Phiên bản Python"
    local check_failed=0
    local py_version=""
    if ! command -v python3 &> /dev/null; then
        log "FAIL" "1.3 Python 3 chưa được cài đặt."
        check_failed=1
    else
        py_version=$(python3 --version 2>&1 | awk '{print $2}')
        # So sánh phiên bản >= 3.6
        if printf '%s\n' "3.6" "$py_version" | sort -V -C; then
             log "PASS" "1.3 Đã cài đặt phiên bản Python $py_version (đáp ứng >= 3.6+)."
        else
             log "FAIL" "1.3 Phiên bản Python $py_version không đáp ứng yêu cầu (>= 3.6+)."
             check_failed=1
        fi
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "1.3 Đang chạy apt install python3..."
        # Không cần update nữa nếu đã chạy ở 1.2
        run_cmd "sudo apt-get install -y python3" && {
            py_version=$(python3 --version 2>&1 | awk '{print $2}')
             if printf '%s\n' "3.6" "$py_version" | sort -V -C; then
                 log "PASS" "1.3 REMEDIATED: Đã cập nhật Python 3 lên $py_version."
                 ((AUDIT_FAILED_COUNT--))
             else
                 log "FAIL" "1.3 REMEDIATION FAILED: Cập nhật Python thất bại hoặc phiên bản không đúng sau khi cài."
             fi
        } || log "FAIL" "1.3 REMEDIATION FAILED: Lỗi trong quá trình install Python."
    fi
}

# --- 1.4: Latest Cassandra installed (Automated) ---
audit_1_4() {
    log "INFO" "1.4 Bắt đầu kiểm tra: Phiên bản Cassandra (>= $MIN_CASSANDRA_VERSION)"
    local check_failed=0
    local current_version=""
    if ! command -v cassandra &> /dev/null; then
        log "FAIL" "1.4 Cassandra chưa được cài đặt."
        check_failed=1
    else
        current_version=$(cassandra -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

        if [ -z "$current_version" ]; then
             log "FAIL" "1.4 Không thể xác định phiên bản Cassandra."
             check_failed=1
        elif printf '%s\n%s\n' "$MIN_CASSANDRA_VERSION" "$current_version" | sort -V -C; then
            log "PASS" "1.4 Đã cài đặt phiên bản Cassandra $current_version (đáp ứng >= $MIN_CASSANDRA_VERSION)."
        else
            log "FAIL" "1.4 Phiên bản Cassandra $current_version không đáp ứng yêu cầu (>= $MIN_CASSANDRA_VERSION)."
            check_failed=1
        fi
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "1.4 Đang chạy apt install cassandra..."
        run_cmd "sudo apt-get install -y cassandra" && {
            current_version=$(cassandra -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            if [ -n "$current_version" ] && printf '%s\n%s\n' "$MIN_CASSANDRA_VERSION" "$current_version" | sort -V -C; then
                log "PASS" "1.4 REMEDIATED: Đã cập nhật Cassandra lên $current_version."
                ((AUDIT_FAILED_COUNT--))
            else
                log "FAIL" "1.4 REMEDIATION FAILED: Cập nhật Cassandra thất bại hoặc phiên bản không đúng sau khi cài."
            fi
        } || log "FAIL" "1.4 REMEDIATION FAILED: Lỗi trong quá trình install Cassandra."
    fi
}


# --- 1.5: Service run as non-root user (Automated) ---
audit_1_5() {
    log "INFO" "1.5 Bắt đầu kiểm tra: User chạy dịch vụ Cassandra"
    local process_user
    process_user=$(ps -eo user:20,pid,ppid,c,stime,tty,time,cmd | grep cassandra | grep java | awk '{print $1}' | uniq)
    local check_failed=0

    if [ -z "$process_user" ]; then
        log "INFO" "1.5 Dịch vụ Cassandra dường như không chạy. Bỏ qua kiểm tra."
        return
    fi

    if [[ "$process_user" == "cassandra" ]]; then
        log "PASS" "1.5 Dịch vụ Cassandra đang chạy với user 'cassandra'."
    else
        log "FAIL" "1.5 Dịch vụ Cassandra đang chạy với user '$process_user' (phải là 'cassandra')."
        check_failed=1
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        if [ -f "$CASSANDRA_SERVICE_FILE" ]; then
            log "REMEDIATE" "1.5 Đang cấu hình $CASSANDRA_SERVICE_FILE để chạy với user/group 'cassandra'..."
            backup "$CASSANDRA_SERVICE_FILE" || return # Dừng nếu backup lỗi

            # Gộp các lệnh thành một khối để kiểm tra thành công chung
            {
                run_cmd "sudo sed -i 's/^User=.*/User=cassandra/' \"$CASSANDRA_SERVICE_FILE\"" && \
                run_cmd "sudo sed -i 's/^Group=.*/Group=cassandra/' \"$CASSANDRA_SERVICE_FILE\"" && \
                run_cmd "sudo systemctl daemon-reload" && \
                run_cmd "sudo systemctl restart cassandra"
            } && {
                log "INFO" "1.5 Chờ Cassandra khởi động lại..."
                sleep 5 # Chờ dịch vụ khởi động
                local new_user
                new_user=$(ps -aef | grep "[j]ava.*cassandra" | awk '{print $1}')
                if [[ "$new_user" == "cassandra" ]]; then
                    log "PASS" "1.5 REMEDIATED: Dịch vụ đã khởi động lại với user 'cassandra'."
                    ((AUDIT_FAILED_COUNT--))
                else
                    # Nếu restart thành công nhưng user vẫn sai, log là lỗi logic
                    log "FAIL" "1.5 REMEDIATION FAILED: Dịch vụ vẫn chạy với user '$new_user' sau khi restart."
                fi
            } || log "FAIL" "1.5 REMEDIATION FAILED: Lỗi khi sửa file service hoặc restart Cassandra."

        else
            log "FAIL" "1.5 REMEDIATION FAILED: Không tìm thấy file service tại $CASSANDRA_SERVICE_FILE. Cần sửa thủ công."
        fi
    fi
}

# --- 1.6: Clocks synchronized on all nodes (Manual) ---
audit_1_6() {
    log "INFO" "1.6 Bắt đầu kiểm tra: Dịch vụ đồng bộ thời gian (NTP)"
    local ntp_active=0
    local service_name=""
    local check_failed=0

    # Kiểm tra các dịch vụ NTP phổ biến
    if systemctl is-active --quiet chrony; then
        ntp_active=1
        service_name="chrony"
    elif systemctl is-active --quiet ntpd; then
        ntp_active=1
        service_name="ntpd"
    elif systemctl is-active --quiet systemd-timesyncd; then # Thêm kiểm tra systemd-timesyncd
         ntp_active=1
         service_name="systemd-timesyncd"
    elif systemctl is-active --quiet ntp; then
         ntp_active=1
         service_name="ntp"
    fi

    if [ $ntp_active -eq 1 ]; then
        log "PASS" "1.6 Dịch vụ đồng bộ thời gian ($service_name) đang chạy."
    else
        log "FAIL" "1.6 Không có dịch vụ đồng bộ thời gian (chrony/ntpd/systemd-timesyncd/ntp) nào đang chạy."
        check_failed=1
    fi

    if [ $check_failed -eq 1 ] && [ $REMEDIATE -eq 1 ]; then
        log "REMEDIATE" "1.6 Đang cài đặt và kích hoạt 'chrony' (khuyến nghị)..."
        # Không cần update nữa
        run_cmd "sudo apt-get install -y chrony" && \
        run_cmd "sudo systemctl enable --now chrony" && {
            if systemctl is-active --quiet chrony; then
                log "PASS" "1.6 REMEDIATED: Đã cài đặt và khởi động 'chrony'."
                ((AUDIT_FAILED_COUNT--))
            else
                log "FAIL" "1.6 REMEDIATION FAILED: Kích hoạt 'chrony' thất bại sau khi cài."
            fi
        } || log "FAIL" "1.6 REMEDIATION FAILED: Cài đặt 'chrony' thất bại."
    fi
}

# --- Hàm Chính ---
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

    # Reset biến đếm lỗi
    AUDIT_FAILED_COUNT=0

    log "INFO" "====================================================================="
    log "INFO" "BẮT ĐẦU AUDIT PHẦN 1 (Installation and Updates)"
    log "INFO" "Remediation mode: $REMEDIATE (1=On, 0=Off)"
    log "INFO" "Log file: $LOG_FILE"
    log "INFO" "====================================================================="

    audit_1_1
    audit_1_2
    audit_1_3
    audit_1_4
    audit_1_5
    audit_1_6

    log "INFO" "====================================================================="
    log "INFO" "KẾT THÚC AUDIT PHẦN 1"

    # Đếm lại số lỗi thực tế từ biến đếm
    local final_fail_count=$AUDIT_FAILED_COUNT

    if [ $final_fail_count -eq 0 ]; then
        log "PASS" "TỔNG KẾT: Tất cả các mục kiểm tra đều PASS."
    else
        log "FAIL" "TỔNG KẾT: Có $final_fail_count mục kiểm tra bị FAIL."
    fi
    log "INFO" "====================================================================="

    if [ $REMEDIATE -eq 1 ]; then
        log "INFO" "Quá trình remediation đã hoàn tất. Một số thay đổi có thể cần khởi động lại Cassandra hoặc hệ thống."
    fi

    # Trả về số lỗi làm exit code
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
