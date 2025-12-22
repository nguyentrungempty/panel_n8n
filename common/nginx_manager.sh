#!/usr/bin/env bash

# Nginx Manager - Quản lý cấu hình Nginx tập trung
# Tất cả thao tác Nginx phải qua module này để tránh xung đột

readonly NGINX_LOCK_FILE="/tmp/n8n_nginx_config.lock"
readonly NGINX_LOCK_TIMEOUT=120  # 2 phút (đủ cho config + reload)
readonly NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
readonly NGINX_CONFIG_NAME="n8n"

# Acquire lock để tránh race condition
acquire_nginx_lock() {
    local wait_time=0
    local max_wait=30
    
    while [ -f "$NGINX_LOCK_FILE" ]; do
        if [ $wait_time -ge $max_wait ]; then
            log_message "ERROR" "Không thể acquire nginx lock sau ${max_wait}s"
            return 1
        fi
        
        # Kiểm tra stale lock
        local lock_age=$(($(date +%s) - $(stat -c %Y "$NGINX_LOCK_FILE" 2>/dev/null || echo 0)))
        if [ $lock_age -gt $NGINX_LOCK_TIMEOUT ]; then
            log_message "WARNING" "Phát hiện stale nginx lock (${lock_age}s), đang xóa..."
            rm -f "$NGINX_LOCK_FILE"
            break
        fi
        
        log_message "INFO" "Đang chờ nginx lock... (${wait_time}s)"
        sleep 2
        wait_time=$((wait_time + 2))
    done
    
    echo "$$" > "$NGINX_LOCK_FILE"
    log_message "INFO" "Đã acquire nginx lock (PID: $$)"
    return 0
}

# Release lock
release_nginx_lock() {
    if [ -f "$NGINX_LOCK_FILE" ]; then
        local lock_pid=$(cat "$NGINX_LOCK_FILE" 2>/dev/null)
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$NGINX_LOCK_FILE"
            log_message "INFO" "Đã release nginx lock (PID: $$)"
        fi
    fi
}

# Trap để đảm bảo release lock (chỉ set nếu chưa có trap khác)
# Sử dụng function để có thể gọi từ trap chung
_nginx_cleanup() {
    release_nginx_lock
}

# Kiểm tra Nginx có được cài đặt không
check_nginx_installed() {
    if ! command -v nginx &> /dev/null; then
        log_message "ERROR" "Nginx chưa được cài đặt"
        return 1
    fi
    return 0
}

# Kiểm tra Nginx có đang chạy không
check_nginx_running() {
    if systemctl is-active --quiet nginx 2>/dev/null; then
        return 0
    fi
    return 1
}

# Backup cấu hình Nginx hiện tại
backup_nginx_config() {
    local config_file="$NGINX_SITES_AVAILABLE/$NGINX_CONFIG_NAME"
    
    if [ -f "$config_file" ]; then
        local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"
        log_message "INFO" "Đã backup Nginx config: $backup_file"
        return 0
    fi
    return 1
}

# Tạo cấu hình Nginx HTTP only (cho Let's Encrypt validation)
generate_nginx_http_only() {
    local domain="$1"
    local ipv6="$2"
    
    local ipv6_listen=""
    if [ "$ipv6" = "true" ]; then
        ipv6_listen="    listen [::]:80;"
    fi
    
    cat <<EOF
server {
    listen 80;
${ipv6_listen}
    server_name ${domain};
    
    root /var/www/html;
    client_max_body_size 50M;
    
    # Let's Encrypt validation
    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }
    
    # Proxy to n8n
    location / {
        proxy_pass http://localhost:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        
        # Timeouts
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
        send_timeout 600;
    }
    
    # Gzip compression
    gzip on;
    gzip_comp_level 4;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
}
EOF
}

# Tạo cấu hình Nginx với SSL
generate_nginx_with_ssl() {
    local domain="$1"
    local ipv6="$2"
    
    local ipv6_ssl_listen=""
    local ipv6_http_listen=""
    
    if [ "$ipv6" = "true" ]; then
        ipv6_ssl_listen="    listen [::]:443 ssl http2;"
        ipv6_http_listen="    listen [::]:80;"
    fi
    
    cat <<EOF
# HTTPS server
server {
    listen 443 ssl http2;
${ipv6_ssl_listen}
    server_name ${domain};
    
    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    
    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    
    client_max_body_size 50M;
    
    # Proxy to n8n
    location / {
        proxy_pass http://localhost:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        
        # Timeouts
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
        send_timeout 600;
        
        # Buffering
        proxy_buffering off;
        proxy_buffer_size 4k;
    }
    
    # Deny access to hidden files
    location ~ /\.ht {
        deny all;
    }
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
}

# HTTP redirect to HTTPS
server {
    listen 80;
${ipv6_http_listen}
    server_name ${domain};
    
    # Let's Encrypt validation
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Redirect to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

# Áp dụng cấu hình Nginx
# Note: Sử dụng check_ssl_exists() từ ssl_manager.sh
apply_nginx_config() {
    local domain="$1"
    local force_http="${2:-false}"
    
    if ! check_nginx_installed; then
        return 1
    fi
    
    # Kiểm tra dependency: ssl_manager phải được load trước
    if ! type check_ssl_exists &>/dev/null; then
        log_message "ERROR" "DEPENDENCY ERROR: ssl_manager.sh phải được source trước nginx_manager.sh"
        log_message "ERROR" "Kiểm tra thứ tự source trong n8n.sh"
        # Fallback inline để tránh crash
        check_ssl_exists() {
            local domain="$1"
            [ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ] && \
            [ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]
        }
    fi
    
    # Acquire lock
    if ! acquire_nginx_lock; then
        return 1
    fi
    
    # Backup cấu hình cũ
    backup_nginx_config
    
    # Phát hiện IPv6
    local has_ipv6="false"
    if type get_server_ipv6 &>/dev/null; then
        local ipv6=$(get_server_ipv6)
        if [ -n "$ipv6" ]; then
            has_ipv6="true"
            log_message "INFO" "Phát hiện IPv6: $ipv6"
        fi
    fi
    
    # Quyết định loại cấu hình
    local config_content=""
    local config_type=""
    
    if [ "$force_http" = "true" ]; then
        config_type="HTTP only"
        config_content=$(generate_nginx_http_only "$domain" "$has_ipv6")
    elif check_ssl_exists "$domain"; then
        config_type="HTTPS with SSL"
        config_content=$(generate_nginx_with_ssl "$domain" "$has_ipv6")
    else
        config_type="HTTP only (no SSL)"
        config_content=$(generate_nginx_http_only "$domain" "$has_ipv6")
    fi
    
    log_message "INFO" "Tạo cấu hình Nginx: $config_type"
    
    # Ghi cấu hình
    echo "$config_content" | sudo tee "$NGINX_SITES_AVAILABLE/$NGINX_CONFIG_NAME" > /dev/null
    
    # Enable site
    if [ ! -d "$NGINX_SITES_ENABLED" ]; then
        sudo mkdir -p "$NGINX_SITES_ENABLED"
    fi
    
    # Remove old symlink if exists
    if [ -L "$NGINX_SITES_ENABLED/$NGINX_CONFIG_NAME" ] || [ -f "$NGINX_SITES_ENABLED/$NGINX_CONFIG_NAME" ]; then
        sudo rm -f "$NGINX_SITES_ENABLED/$NGINX_CONFIG_NAME"
    fi
    
    # Create new symlink
    sudo ln -sf "$NGINX_SITES_AVAILABLE/$NGINX_CONFIG_NAME" "$NGINX_SITES_ENABLED/$NGINX_CONFIG_NAME"
    
    # Test cấu hình
    log_message "INFO" "Kiểm tra cấu hình Nginx..."
    if sudo nginx -t 2>&1 | tee /tmp/nginx_test.log; then
        log_message "SUCCESS" "Cấu hình Nginx hợp lệ"
        
        # Reload Nginx
        if check_nginx_running; then
            log_message "INFO" "Reload Nginx..."
            if sudo systemctl reload nginx; then
                log_message "SUCCESS" "Đã reload Nginx thành công"
            else
                log_message "WARNING" "Không thể reload Nginx, thử restart..."
                sudo systemctl restart nginx
            fi
        else
            log_message "INFO" "Khởi động Nginx..."
            sudo systemctl start nginx
        fi
        
        # Release lock
        release_nginx_lock
        return 0
    else
        log_message "ERROR" "Cấu hình Nginx không hợp lệ"
        cat /tmp/nginx_test.log
        
        # Release lock
        release_nginx_lock
        return 1
    fi
}

# Xóa cấu hình Nginx
remove_nginx_config() {
    if ! check_nginx_installed; then
        return 0
    fi
    
    # Acquire lock
    if ! acquire_nginx_lock; then
        return 1
    fi
    
    log_message "INFO" "Xóa cấu hình Nginx cho n8n..."
    
    # Backup trước khi xóa
    backup_nginx_config
    
    # Remove symlink
    if [ -L "$NGINX_SITES_ENABLED/$NGINX_CONFIG_NAME" ]; then
        sudo rm -f "$NGINX_SITES_ENABLED/$NGINX_CONFIG_NAME"
        log_message "INFO" "Đã xóa symlink"
    fi
    
    # Remove config file
    if [ -f "$NGINX_SITES_AVAILABLE/$NGINX_CONFIG_NAME" ]; then
        sudo rm -f "$NGINX_SITES_AVAILABLE/$NGINX_CONFIG_NAME"
        log_message "INFO" "Đã xóa config file"
    fi
    
    # Reload Nginx
    if check_nginx_running; then
        sudo systemctl reload nginx
        log_message "SUCCESS" "Đã reload Nginx"
    fi
    
    # Release lock
    release_nginx_lock
    return 0
}

# Test Nginx configuration
test_nginx_config() {
    if ! check_nginx_installed; then
        echo "Nginx chưa được cài đặt"
        return 1
    fi
    
    echo "Đang test cấu hình Nginx..."
    if sudo nginx -t; then
        echo "✅ Cấu hình Nginx hợp lệ"
        return 0
    else
        echo "❌ Cấu hình Nginx không hợp lệ"
        return 1
    fi
}

# Reload Nginx
reload_nginx() {
    if ! check_nginx_installed; then
        return 1
    fi
    
    log_message "INFO" "Reload Nginx..."
    
    if check_nginx_running; then
        if sudo systemctl reload nginx; then
            log_message "SUCCESS" "Đã reload Nginx"
            return 0
        else
            log_message "WARNING" "Không thể reload, thử restart..."
            sudo systemctl restart nginx
            return $?
        fi
    else
        log_message "INFO" "Nginx không chạy, đang khởi động..."
        sudo systemctl start nginx
        return $?
    fi
}

# Restart Nginx
restart_nginx() {
    if ! check_nginx_installed; then
        return 1
    fi
    
    log_message "INFO" "Restart Nginx..."
    
    if sudo systemctl restart nginx; then
        log_message "SUCCESS" "Đã restart Nginx"
        return 0
    else
        log_message "ERROR" "Không thể restart Nginx"
        return 1
    fi
}

# Stop Nginx
stop_nginx() {
    if ! check_nginx_installed; then
        return 0
    fi
    
    log_message "INFO" "Dừng Nginx..."
    
    if sudo systemctl stop nginx; then
        log_message "SUCCESS" "Đã dừng Nginx"
        return 0
    else
        log_message "ERROR" "Không thể dừng Nginx"
        return 1
    fi
}

# Start Nginx
start_nginx() {
    if ! check_nginx_installed; then
        return 1
    fi
    
    log_message "INFO" "Khởi động Nginx..."
    
    if sudo systemctl start nginx; then
        log_message "SUCCESS" "Đã khởi động Nginx"
        return 0
    else
        log_message "ERROR" "Không thể khởi động Nginx"
        return 1
    fi
}

# Hàm wrapper cho Python/webhook
apply_nginx_config_json() {
    local domain="$1"
    local force_http="${2:-false}"
    
    if apply_nginx_config "$domain" "$force_http"; then
        echo '{"success": true, "message": "Nginx configured successfully", "domain": "'"$domain"'"}'
        return 0
    else
        echo '{"success": false, "message": "Failed to configure Nginx", "domain": "'"$domain"'"}'
        return 1
    fi
}
