# N8N Panel v3.1

Panel quản lý N8N tự động cho Ubuntu Server - Hỗ trợ Docker, PostgreSQL, SSL, Backup và Multi-Instance.


## 🚀 Tính năng chính

| Tính năng | Mô tả |
|-----------|-------|
| **Cài đặt tự động** | Cài đặt N8N + PostgreSQL + Nginx + SSL chỉ với 1 lệnh |
| **Multi-Instance** | Chạy nhiều N8N instances trên cùng 1 VPS với giao diện chọn instance trực quan |
| **Quản lý SSL** | Tự động cài đặt và gia hạn Let's Encrypt SSL |
| **Backup/Restore** | Backup tự động theo lịch, restore dễ dàng |
| **Quản lý Domain** | Thay đổi domain không cần cài lại |
| **Docker Management** | Quản lý containers, logs, restart |
| **Webhook Hook** | Python webhook server cho automation |

## 📋 Yêu cầu hệ thống

- **OS:** Ubuntu 20.04 / 22.04 / 24.04
- **RAM:** Tối thiểu 1GB (khuyến nghị 2GB+)
- **Disk:** Tối thiểu 10GB
- **Quyền:** Root access

## ⚡ Cài đặt nhanh

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/main/install_v3.sh | bash
```

Hoặc cài đặt thủ công:

```bash
# Clone repo
git clone https://github.com/YOUR_REPO/panel_n8n.git /opt/n8npanel/v3

# Cấp quyền và chạy
chmod +x /opt/n8npanel/v3/n8n.sh
ln -sf /opt/n8npanel/v3/n8n.sh /usr/local/bin/n8n

# Khởi động panel
n8n
```

## 📁 Cấu trúc thư mục

```
v3/
├── n8n.sh                      # Script chính
├── manifest.json               # Thông tin version và files
├── hook.py                     # Webhook server (Python)
├── install_v3.sh               # Script cài đặt
│
├── common/                     # Modules dùng chung
│   ├── utils.sh                # Hàm tiện ích
│   ├── network.sh              # Quản lý network
│   ├── nginx_manager.sh        # Quản lý Nginx
│   ├── ssl_manager.sh          # Quản lý SSL
│   ├── env_manager.sh          # Quản lý .env
│   ├── domain_manager.sh       # Quản lý domain
│   ├── restart_manager.sh      # Quản lý restart containers
│   ├── instance_selector.sh    # Chọn instance (Multi-Instance)
│   ├── domain_change_wrapper.sh
│   ├── nginx_config_wrapper.sh
│   └── ssl_install_wrapper.sh
│
├── 1_Cai_dat_n8n_moi/          # Module cài đặt
│   └── install.sh
│
├── 2_Quan_ly_Backup/           # Module backup
│   └── backup.sh
│
├── 3_Quan_ly_SSL/              # Module SSL
│   └── ssl.sh
│
├── 4_Quan_ly_Docker_Container/ # Module Docker
│   └── docker.sh
│
├── 5_Quan_ly_N8N/              # Module quản lý N8N
│   └── manage.sh
│
├── 6_Xem_thong_tin_he_thong/   # Module system info
│   └── system_info.sh
│
├── 7_Cap_nhat/                 # Module cập nhật
│   └── update.sh
│
├── 8_Multi_Instance/           # Module multi-instance
│   └── multi_instance.sh
│
└── 9_Go_cai_dat/               # Module gỡ cài đặt
    └── uninstall.sh
```

## 🎯 Menu chính

```
╔══════════════════════════════════════════════════════════════════════════════════════╗
║                           N8N AUTO INSTALLER & MANAGER v3.1                          ║
╚══════════════════════════════════════════════════════════════════════════════════════╝

  CÀI ĐẶT & QUẢN LÝ                         CÔNG CỤ & BẢO TRÌ
  ───────────────────────                   ──────────────────────────
  1. Cài đặt n8n mới (Full)                 5. Quản lý N8N
  2. Quản lý Backup                         6. Xem thông tin hệ thống
  3. Quản lý SSL                            7. Cập nhật
  4. Quản lý Docker Container               8. Multi-Instance N8N

  9. Gỡ cài đặt                             0. Thoát
```

### Instance Selector (Multi-Instance)

Khi có nhiều instances, hệ thống sẽ hiển thị bảng chọn instance:

```
═══════════════════════════════════════════════════════════════
                    CHỌN INSTANCE N8N
═══════════════════════════════════════════════════════════════

Chọn instance để thao tác:

  ID   Domain                    Status          Port
  ────────────────────────────────────────────────────────────
  1    domain1.com               ✅ Running      5678
  2    domain2.com               ✅ Running      5679

  0. Hủy / Quay lại

Nhập ID instance [0-2]:
```

## 🔧 Các tính năng chi tiết

### 1. Cài đặt N8N mới
- Cài đặt Docker, Docker Compose
- Cài đặt Nginx làm reverse proxy
- Cài đặt PostgreSQL database
- Cài đặt N8N với cấu hình tối ưu
- Tự động cài SSL Let's Encrypt

### 2. Quản lý Backup
- Backup thủ công
- Backup tự động theo lịch (cron)
- Restore từ file backup
- Backup bao gồm: database, workflows, credentials

### 3. Quản lý SSL
- Cài đặt SSL Let's Encrypt
- Gia hạn SSL
- Kiểm tra trạng thái SSL
- Hỗ trợ wildcard SSL

### 4. Quản lý Docker
- Xem trạng thái containers
- Restart containers
- Xem logs
- Dọn dẹp Docker (images, volumes không dùng)

### 5. Quản lý N8N
- Reset mật khẩu user
- Thay đổi domain
- Cấu hình LDAP
- Bật/tắt MFA
- Xem thông tin đăng nhập

### 6. Xem thông tin hệ thống
- Thông tin server (CPU, RAM, Disk)
- Thông tin N8N (version, domain, port)
- Thông tin database
- Thông tin SSL

### 7. Cập nhật
- Cập nhật N8N lên version mới nhất
- Cập nhật Panel
- Quản lý cấu hình mạng (IPv4/IPv6)

### 8. Multi-Instance N8N
- Tạo nhiều N8N instances trên 1 VPS
- Mỗi instance có domain, port, database riêng
- Quản lý (start/stop/restart) từng instance
- Xóa instance
- **Instance Selector**: Giao diện chọn instance trực quan với bảng hiển thị ID, Domain, Status, Port
- Tất cả tính năng (Backup, SSL, Docker, N8N Management, Update) đều hỗ trợ multi-instance

### 9. Gỡ cài đặt
- Xóa hoàn toàn N8N và các thành phần
- Tạo backup trước khi xóa
- Giữ lại Docker và Nginx

## 🌐 Webhook Server (hook.py)

Python webhook server cho phép automation qua HTTP API:

```bash
# Chạy webhook server
python3 /opt/n8n/hook.py 8888
```

### API Endpoints:

| Endpoint | Method | Mô tả |
|----------|--------|-------|
| `/health` | GET | Kiểm tra server |
| `/change-domain` | POST | Thay đổi domain |
| `/install-ssl` | POST | Cài đặt SSL |
| `/nginx-config` | POST | Cấu hình Nginx |

## 📝 Thư mục dữ liệu

| Đường dẫn | Mô tả |
|-----------|-------|
| `/root/n8n_data/` | Dữ liệu N8N instance 1 |
| `/root/n8n_data_2/` | Dữ liệu N8N instance 2 |
| `/root/n8n_data/.env` | Biến môi trường |
| `/root/n8n_data/docker-compose.yml` | Docker compose config |
| `/root/n8n_data/backups/` | Thư mục backup |
| `/var/log/n8npanel/` | Log files |
| `/opt/n8npanel/v3/` | Panel installation |

## 🔐 Credentials Format

Credentials được tạo tự động theo format:
- **Username:** `n8n_inet<ip_sum>` (instance 1) hoặc `n8n_inet<id>_<ip_sum>` (multi-instance)
- **Password:** Tương tự username
- **Database:** `n8n_inet<ip_sum>` hoặc `n8n_inet<id>`

Trong đó `ip_sum` = tổng các số trong IP server (vd: 103.75.186.126 → 490)

## 📊 Changelog v3.1 (2025-12-03)

### Multi-Instance N8N
- Chạy nhiều N8N instances trên cùng 1 VPS
- Mỗi instance có domain, port, database riêng biệt
- Instance Selector: giao diện chọn instance trực quan với bảng ID/Domain/Status/Port
- Tất cả tính năng (Backup, SSL, Docker, N8N, Update) hỗ trợ multi-instance

### Cải thiện chất lượng
- Fix hook.py regex patterns (CRITICAL)
- Fix credentials format đúng (n8n_inet<id>_<ip_sum>)
- Đợi PostgreSQL healthy trước khi khởi động N8N
- Validation functions cho domain và env values
- Log rotation và tập trung log files

### Kiến trúc Modular
- Cấu trúc modular với common modules
- Instance Selector, Restart Manager, SSL Manager, Domain Manager
- Wrapper scripts cho automation

> 📖 Xem chi tiết tại [CHANGELOG.md](CHANGELOG.md)

