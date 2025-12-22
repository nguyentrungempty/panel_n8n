#!/usr/bin/env bash

# Nginx Config Wrapper for Python/Webhook
# Script này được gọi từ hook.py để cấu hình Nginx

# Thiết lập môi trường
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

# Sử dụng biến môi trường nếu có, nếu không dùng giá trị mặc định
N8N_DATA_DIR="${N8N_DATA_DIR:-/root/n8n_data}"
BACKUP_DIR="${BACKUP_DIR:-$N8N_DATA_DIR/backups}"

# Colors (định nghĩa local vì wrapper chạy standalone)
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# Source các module cần thiết
source "$INSTALL_DIR/common/utils.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load utils.sh"}'
    exit 1
}

source "$INSTALL_DIR/common/network.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load network.sh"}'
    exit 1
}

# ssl_manager PHẢI được load trước nginx_manager (dependency)
source "$INSTALL_DIR/common/ssl_manager.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load ssl_manager.sh"}'
    exit 1
}

source "$INSTALL_DIR/common/nginx_manager.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load nginx_manager.sh"}'
    exit 1
}

# Cleanup function for trap (chỉ khi chạy standalone)
cleanup_wrapper() {
    # Release Nginx lock if held by this process
    rm -f "/tmp/n8n_nginx_config.lock" 2>/dev/null
}

# Trap để cleanup khi bị interrupt (chỉ khi chạy standalone, không phải sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup_wrapper EXIT INT TERM
fi

# Parse arguments
DOMAIN="$1"
FORCE_HTTP="${2:-false}"

# Validate input
if [ -z "$DOMAIN" ]; then
    echo '{"success": false, "error": "Domain is required"}'
    exit 1
fi

# Validate domain format
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9\.-]*[a-zA-Z0-9]$ ]]; then
    echo '{"success": false, "error": "Invalid domain format"}'
    exit 1
fi

# Log to centralized log file
LOG_DIR="${LOG_DIR:-/var/log/n8npanel}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/n8n_panel.log}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [NGINX_CONFIG] Configuring Nginx for: $DOMAIN (Force HTTP: $FORCE_HTTP)" >> "$LOG_FILE"

# Gọi hàm từ nginx_manager
if apply_nginx_config_json "$DOMAIN" "$FORCE_HTTP"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [NGINX_CONFIG] Nginx configuration successful: $DOMAIN" >> "$LOG_FILE"
    exit 0
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [NGINX_CONFIG] Nginx configuration failed: $DOMAIN" >> "$LOG_FILE"
    exit 1
fi
