
# NT542.Q11 - CIS Apache Cassandra 4.0 Benchmark Automation

**Đồ án môn học: Lập trình kịch bản tự động hóa cho quản trị và bảo mật mạng**   
**Nhóm thực hiện:** Nhóm 04

---

## 📖 Giới thiệu (Introduction)

Dự án này cung cấp bộ công cụ tự động hóa việc **Cài đặt**, **Cấu hình Cluster**, và **Kiểm định/Khắc phục bảo mật (Audit & Remediate)** cho hệ quản trị cơ sở dữ liệu **Apache Cassandra 4.0** dựa trên tiêu chuẩn an toàn thông tin **CIS Benchmark v1.1.0**.

Giải pháp được triển khai theo hai phương pháp:
1.  **Local Bash Scripts:** Chạy trực tiếp trên từng node.
2.  **Ansible Automation:** Triển khai đồng loạt trên nhiều node từ máy quản trị (Control Node) theo mô hình "Ansible Wrapper".

## 👥 Thành viên thực hiện (Team Members)

| STT | Họ và tên | MSSV | Vai trò chính |
|-----|--------------------|----------|----------------------------------------------------------|
| 1 | **Lê Ngọc Kiều Anh** | 22520047 | Nghiên cứu CIS Section 1, 2, 3; Báo cáo & Slide. |
| 2 | **Phùng Việt Bắc** | 22520089 | Viết Bash Script (Install, Configure), Audit Section 1-4.|
| 3 | **Trần Phước Đại** | 22520184 | Triển khai Ansible, Audit Section 3,4,5 (Encryption/TLS). |

---

## 📂 Cấu trúc dự án (Project Structure)

```text
.
├── 1-install_cassandra.sh         # Script cài đặt: Java, Python, Cassandra 4.0, Chrony, User setup
├── 2-configure_cassandra.sh       # Script cấu hình: Join Cluster, Seed nodes, Rename Cluster
├── 3-audit_remediate_section1.sh  # CIS Section 1: Installation & Updates
├── 4-audit_remediate_section2.sh  # CIS Section 2: Authentication & Authorization
├── 5-audit_remediate_section3.sh  # CIS Section 3: Access Control / Password Policies
├── 6-audit_remediate_section4.sh  # CIS Section 4: Auditing & Logging
├── 7-audit_remediate_section5.sh  # CIS Section 5: Encryption (Inter-node & Client-Server)
├── playbooks/                     # (Thư mục đề xuất) Chứa các Ansible Playbooks
│   ├── 01_install.yml
│   ├── 02_configure.yml
│   └── audit_remediate_sectionX.yml
└── hosts.ini                      # File Inventory cho Ansible

```

---

## 🚀 Yêu cầu hệ thống (Prerequisites)

* **OS:** Ubuntu Server 22.04 LTS.
* **Quyền hạn:** Root (`sudo`) là bắt buộc để cài đặt gói và sửa file cấu hình.
* **Mạng:** Các node phải thông nhau và có IP tĩnh (Static IP).
* **Công cụ:** `curl`, `gnupg`, `python3` (Script sẽ tự động cài nếu thiếu).

---

## 🛠️ Hướng dẫn sử dụng (Local / Manual Mode)

### Bước 1: Cài đặt Cassandra (Chạy trên tất cả các node)

Script này sẽ cập nhật hệ thống, cài Java 11, tạo user `cassandra`, và cài đặt dịch vụ.

```bash
sudo chmod +x install_cassandra.sh
sudo ./install_cassandra.sh

```

### Bước 2: Cấu hình Cluster (Chạy trên tất cả các node)

Script cấu hình IP node, danh sách Seed nodes và tên Cluster.

* **Cú pháp:** `sudo ./Configure_cassandra.sh <IP_CỦA_NODE_NÀY> "<DANH_SÁCH_IP_SEED>"`

**Ví dụ (Node 1 - Seed):**

```bash
sudo ./Configure_cassandra.sh 192.168.28.146 "192.168.28.146,192.168.28.145"

```

**Ví dụ (Node 2 - Member):**

```bash
sudo ./Configure_cassandra.sh 192.168.28.145 "192.168.28.146,192.168.28.145"

```

### Bước 3: Audit & Remediate (Bảo mật theo CIS Benchmark)

Mỗi script tương ứng với một section của CIS. Có 2 chế độ chạy:

* **Chỉ Audit (Kiểm tra):** `./script_name.sh`
* **Audit & Fix (Tự động sửa):** `sudo ./script_name.sh --remediate`

#### Section 1: Installation and Updates

```bash
sudo ./audit_remediate_section1.sh --remediate

```

#### Section 2: Authentication and Authorization

*Bật PasswordAuthenticator và CassandraAuthorizer.*

```bash
sudo ./audit_remediate_section2.sh --remediate

```

#### Section 3: Access Control / Password Policies

*Lưu ý: Mật khẩu mới được hardcode trong biến `CASSANDRA_NEW_PASSWORD` của script (mặc định: `group04_cassandra`). Hãy sửa lại nếu cần.*

```bash
sudo ./audit_remediate_section3.sh --remediate

```

#### Section 4: Auditing and Logging

*Bật Audit Logging và Logback level INFO.*

```bash
sudo ./audit_remediate_section4.sh --remediate

```

#### Section 5: Encryption (TLS/SSL)

⚠️ **QUAN TRỌNG:** Trước khi chạy script Section 5, ta **PHẢI** tạo và copy Keystore/Truststore vào `/etc/cassandra/` cho từng node.

1. Tạo CA, Server Keystore, Truststore (sử dụng `openssl` và `keytool`).
2. Copy file `nodeX.keystore` và `cassandra.truststore` vào `/etc/cassandra/`.
3. Sau đó mới chạy script:

```bash
sudo ./audit_remediate_section5.sh --remediate

```

---

## 🤖 Hướng dẫn sử dụng (Ansible Remote Mode)

Sử dụng **Ansible** để điều phối các script trên thay vì chạy thủ công từng máy (Chiến thuật Ansible Wrapper).

### 1. Cấu hình Inventory (`hosts.ini`)

```ini
[cassandra_nodes]
192.168.28.146
192.168.28.145
192.168.28.147

[cassandra_nodes:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
seed_list="192.168.28.146,192.168.28.145"

```

### 2. Chạy Playbook triển khai

Sử dụng lệnh `ansible-playbook` để chạy các file YAML (được wrapper quanh các file bash script):

```bash
# Cài đặt
ansible-playbook -i hosts.ini playbooks/01_install.yml

# Cấu hình Cluster
ansible-playbook -i hosts.ini playbooks/02_configure.yml

# Thực hiện bảo mật (Ví dụ Section 1)
ansible-playbook -i hosts.ini playbooks/audit_remediate_section1.yml

```

---

## 📊 CIS Benchmark Coverage

| Section | Tên hạng mục | Trạng thái Automation | Script |
| --- | --- | --- | --- |
| **1** | Installation and Updates | ✅ Full | `3-audit...sh` |
| **2** | Authentication and Authorization | ✅ Full | `4-audit...sh` |
| **3** | Access Control / Password Policies | ⚠️ Partial* | `5-audit...sh` |
| **4** | Auditing and Logging | ✅ Full | `6-audit...sh` |
| **5** | Encryption (Inter-node & Client) | ✅ Full** | `7-audit...sh` |

**Section 3: Một số mục như Network Interface cần kiểm tra thủ công để tránh mất kết nối SSH.* ***Section 5: Yêu cầu chuẩn bị trước chứng chỉ (Certs).*

---

## 📝 Ghi chú & Cảnh báo (Disclaimer)

1. **Backup:** Các script đều có cơ chế backup file cấu hình (`.bak`) vào `/var/backups/cis_cassandra` trước khi chỉnh sửa. Tuy nhiên, hãy backup dữ liệu quan trọng trước khi chạy.
2. **Restart Service:** Chế độ `--remediate` sẽ tự động khởi động lại dịch vụ Cassandra (`systemctl restart cassandra`) để áp dụng cấu hình. Điều này có thể gây gián đoạn dịch vụ tạm thời.
3. **Mật khẩu:** Sau khi chạy Section 3, mật khẩu mặc định `cassandra/cassandra` sẽ bị đổi. Hãy kiểm tra script để lấy mật khẩu mới.

---

© 2025 Nhóm 04 - NT542.Q11 - UIT

```

```
