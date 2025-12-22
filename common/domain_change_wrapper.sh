#!/usr/bin/env bash

# Domain Change Wrapper for Python/Webhook
# Script này được gọi từ hook.py để thay đổi domain
# Sử dụng domain_manager.sh làm backend

# Thiết lập môi trường
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

# Sử dụng biến môi trường nếu có, nếu không dùng giá trị mặc định
N8N_DATA_DIR="${N8N_DATA_DIR:-/root/n8n_data}"
COMPOSE_FILE="${COMPOSE_FILE:-$N8N_DATA_DIR/docker-compose.yml}"
BACKUP_DIR="${BACKUP_DIR:-$N8N_DATA_DIR/backups}"

# Colors (định nghĩa local vì wrapper chạy standalone, không source từ n8n.sh)
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
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

source "$INSTALL_DIR/common/nginx_manager.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load nginx_manager.sh"}'
    exit 1
}

source "$INSTALL_DIR/common/ssl_manager.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load ssl_manager.sh"}'
    exit 1
}

source "$INSTALL_DIR/common/env_manager.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load env_manager.sh"}'
    exit 1
}

source "$INSTALL_DIR/common/domain_manager.sh" 2>/dev/null || {
    echo '{"success": false, "error": "Failed to load domain_manager.sh"}'
    exit 1
}

# Cleanup function for trap (chỉ khi chạy standalone)
cleanup_wrapper() {
    # Release any locks that might be held by this process
    rm -f "/tmp/n8n_domain_change.lock" 2>/dev/null
    rm -f "/tmp/n8n_ssl_install.lock" 2>/dev/null
    rm -f "/tmp/n8n_nginx_config.lock" 2>/dev/null
}

# Trap để cleanup khi bị interrupt (chỉ khi chạy standalone, không phải sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup_wrapper EXIT INT TERM
fi

# Parse arguments
NEW_DOMAIN="$1"
EMAIL="${2:-admin@$NEW_DOMAIN}"
SKIP_SSL="${3:-false}"

# Validate input
if [ -z "$NEW_DOMAIN" ]; then
    echo '{"success": false, "error": "Domain is required"}'
    exit 1
fi

# Validate domain format
if [[ ! "$NEW_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9\.-]*[a-zA-Z0-9]$ ]]; then
    echo '{"success": false, "error": "Invalid domain format"}'
    exit 1
fi

# Validate email format
if [ -n "$EMAIL" ]; then
    if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo '{"success": false, "error": "Invalid email format"}'
        exit 1
    fi
fi

# Log to centralized log file
LOG_DIR="${LOG_DIR:-/var/log/n8npanel}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/n8n_panel.log}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DOMAIN_CHANGE] Starting domain change: $NEW_DOMAIN (Email: $EMAIL)" >> "$LOG_FILE"

# Gọi hàm thống nhất từ domain_manager
if change_domain_unified "$NEW_DOMAIN" "$EMAIL" "$SKIP_SSL" "true"; then
    echo '{"success": true, "message": "Domain changed successfully", "domain": "'"$NEW_DOMAIN"'", "email": "'"$EMAIL"'"}'
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DOMAIN_CHANGE] Domain change successful: $NEW_DOMAIN" >> "$LOG_FILE"
    exit 0
else
    echo '{"success": false, "error": "Failed to change domain", "domain": "'"$NEW_DOMAIN"'"}'
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DOMAIN_CHANGE] Domain change failed: $NEW_DOMAIN" >> "$LOG_FILE"
    exit 1
fi
