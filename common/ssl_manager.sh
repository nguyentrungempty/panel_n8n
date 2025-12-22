#!/usr/bin/env bash

# SSL Manager - Quản lý SSL certificate tập trung
# Hỗ trợ: Let's Encrypt, ZeroSSL, và download từ drive.inet.vn (cho ezn8n.com)

readonly SSL_LOCK_FILE="/tmp/n8n_ssl_install.lock"
readonly SSL_LOCK_TIMEOUT=300  # 5 phút
readonly LETSENCRYPT_DIR="/etc/letsencrypt"
readonly WEBROOT_DIR="/var/www/html"

# Acquire lock để tránh race condition
acquire_ssl_lock() {
    local wait_time=0
    local max_wait=30
    
    while [ -f "$SSL_LOCK_FILE" ]; do
        if [ $wait_time -ge $max_wait ]; then
            log_message "ERROR" "Không thể acquire SSL lock sau ${max_wait}s"
            return 1
        fi
        
        # Kiểm tra stale lock
        local lock_age=$(($(date +%s) - $(stat -c %Y "$SSL_LOCK_FILE" 2>/dev/null || echo 0)))
        if [ $lock_age -gt $SSL_LOCK_TIMEOUT ]; then
            log_message "WARNING" "Phát hiện stale SSL lock (${lock_age}s), đang xóa..."
            rm -f "$SSL_LOCK_FILE"
            break
        fi
        
        log_message "INFO" "Đang chờ SSL lock... (${wait_time}s)"
        sleep 2
        wait_time=$((wait_time + 2))
    done
    
    echo "$$" > "$SSL_LOCK_FILE"
    log_message "INFO" "Đã acquire SSL lock (PID: $$)"
    return 0
}

# Release lock
release_ssl_lock() {
    if [ -f "$SSL_LOCK_FILE" ]; then
        local lock_pid=$(cat "$SSL_LOCK_FILE" 2>/dev/null)
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$SSL_LOCK_FILE"
            log_message "INFO" "Đã release SSL lock (PID: $$)"
        fi
    fi
}

# Trap để đảm bảo release lock (chỉ set nếu chưa có trap khác)
# Sử dụng function để có thể gọi từ trap chung
_ssl_cleanup() {
    release_ssl_lock
}

# Kiểm tra certbot có được cài đặt không
check_certbot_installed() {
    if ! command -v certbot &> /dev/null; then
        log_message "WARNING" "Certbot chưa được cài đặt"
        return 1
    fi
    return 0
}

# Cài đặt certbot nếu chưa có
install_certbot() {
    if check_certbot_installed; then
        return 0
    fi
    
    log_message "INFO" "Đang cài đặt Certbot..."
    
    if sudo apt update && sudo apt install -y certbot python3-certbot-nginx; then
        log_message "SUCCESS" "Đã cài đặt Certbot thành công"
        return 0
    else
        log_message "ERROR" "Không thể cài đặt Certbot"
        return 1
    fi
}

# Kiểm tra domain có phải subdomain của ezn8n.com không
is_ezn8n_subdomain() {
    local domain="$1"
    
    if [[ "$domain" == *.ezn8n.com ]]; then
        return 0
    fi
    return 1
}

# Kiểm tra SSL certificate có tồn tại không
check_ssl_exists() {
    local domain="$1"
    
    if [ -f "$LETSENCRYPT_DIR/live/${domain}/fullchain.pem" ] && \
       [ -f "$LETSENCRYPT_DIR/live/${domain}/privkey.pem" ]; then
        return 0
    fi
    return 1
}

# Xóa toàn bộ SSL certificate cũ cho domain
clean_ssl_certificates() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        log_message "ERROR" "Domain không được để trống"
        return 1
    fi
    
    log_message "INFO" "Xóa toàn bộ SSL certificates cho: $domain"
    
    # 1. Remove from /etc/letsencrypt/live
    if [ -d "$LETSENCRYPT_DIR/live/${domain}" ]; then
        sudo rm -rf "$LETSENCRYPT_DIR/live/${domain}"
        log_message "INFO" "Đã xóa: $LETSENCRYPT_DIR/live/${domain}"
    fi
    
    # 2. Remove from /etc/letsencrypt/archive
    if [ -d "$LETSENCRYPT_DIR/archive/${domain}" ]; then
        sudo rm -rf "$LETSENCRYPT_DIR/archive/${domain}"
        log_message "INFO" "Đã xóa: $LETSENCRYPT_DIR/archive/${domain}"
    fi
    
    # 3. Remove from /etc/letsencrypt/renewal
    if [ -f "$LETSENCRYPT_DIR/renewal/${domain}.conf" ]; then
        sudo rm -f "$LETSENCRYPT_DIR/renewal/${domain}.conf"
        log_message "INFO" "Đã xóa: $LETSENCRYPT_DIR/renewal/${domain}.conf"
    fi
    
    # 4. Try certbot delete (might fail if already removed)
    if check_certbot_installed; then
        sudo certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
    fi
    
    # 5. Clean Nginx SSL cache
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_message "INFO" "Dọn dẹp Nginx SSL cache..."
        sudo systemctl stop nginx 2>/dev/null || true
        sleep 2
        
        # Delete cache directories
        for cache_dir in /var/cache/nginx /etc/nginx/conf.d/ssl /etc/nginx/ssl; do
            if [ -d "$cache_dir" ]; then
                sudo find "$cache_dir" -type f -delete 2>/dev/null || true
            fi
        done
        
        sudo systemctl start nginx 2>/dev/null || true
    fi
    
    log_message "SUCCESS" "Đã xóa toàn bộ SSL certificates cho: $domain"
    return 0
}

# Download SSL certificates từ drive.inet.vn (cho ezn8n.com subdomains)
download_ezn8n_ssl() {
    local domain="$1"
    
    log_message "INFO" "Download SSL certificates từ drive.inet.vn cho: $domain"
    
    local ssl_dir="$LETSENCRYPT_DIR/live/${domain}"
    local archive_dir="$LETSENCRYPT_DIR/archive/${domain}"
    
    # Create directories
    sudo mkdir -p "$ssl_dir" "$archive_dir"
    sudo chmod 755 "$ssl_dir" "$archive_dir"
    
    # Download files
    local base_url="http://drive.inet.vn/uploads/ezn8n"
    local temp_dir="/tmp/ssl_download_$$"
    mkdir -p "$temp_dir"
    
    local files=(
        "certificate.crt"
        "ca_bundle.crt"
        "private.key"
    )
    
    local download_success=true
    
    for file in "${files[@]}"; do
        log_message "INFO" "Downloading: $file"
        
        if curl -s --connect-timeout 30 "${base_url}/${file}" -o "${temp_dir}/${file}"; then
            if [ -s "${temp_dir}/${file}" ]; then
                log_message "SUCCESS" "Downloaded: $file"
            else
                log_message "ERROR" "File rỗng: $file"
                download_success=false
                break
            fi
        else
            log_message "ERROR" "Không thể download: $file"
            download_success=false
            break
        fi
    done
    
    if [ "$download_success" = false ]; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Validate downloaded files
    log_message "INFO" "Kiểm tra định dạng SSL files..."
    
    # Check if files are valid PEM format
    if ! grep -q "BEGIN CERTIFICATE" "${temp_dir}/certificate.crt"; then
        log_message "ERROR" "certificate.crt không phải định dạng PEM hợp lệ"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if ! grep -q "BEGIN CERTIFICATE" "${temp_dir}/ca_bundle.crt"; then
        log_message "ERROR" "ca_bundle.crt không phải định dạng PEM hợp lệ"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if ! grep -q "BEGIN.*PRIVATE KEY" "${temp_dir}/private.key"; then
        log_message "ERROR" "private.key không phải định dạng PEM hợp lệ"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_message "SUCCESS" "Tất cả files đều hợp lệ"
    
    # Clean files: Remove BOM, fix line endings, trim whitespace
    log_message "INFO" "Làm sạch SSL files..."
    for file in certificate.crt ca_bundle.crt private.key; do
        # Remove BOM if exists
        sed -i '1s/^\xEF\xBB\xBF//' "${temp_dir}/${file}" 2>/dev/null || true
        # Convert CRLF to LF
        sed -i 's/\r$//' "${temp_dir}/${file}" 2>/dev/null || true
        # Remove trailing whitespace
        sed -i 's/[[:space:]]*$//' "${temp_dir}/${file}" 2>/dev/null || true
    done
    
    # Create SSL files in Let's Encrypt format
    log_message "INFO" "Tạo SSL files theo format Let's Encrypt..."
    
    # 1. fullchain.pem = certificate.crt + ca_bundle.crt
    cat "${temp_dir}/certificate.crt" "${temp_dir}/ca_bundle.crt" | sudo tee "$ssl_dir/fullchain.pem" > /dev/null
    sudo chmod 644 "$ssl_dir/fullchain.pem"
    
    # 2. chain.pem = ca_bundle.crt
    sudo cp "${temp_dir}/ca_bundle.crt" "$ssl_dir/chain.pem"
    sudo chmod 644 "$ssl_dir/chain.pem"
    
    # 3. privkey.pem = private.key
    sudo cp "${temp_dir}/private.key" "$ssl_dir/privkey.pem"
    sudo chmod 600 "$ssl_dir/privkey.pem"
    
    # 4. cert.pem = certificate.crt
    sudo cp "${temp_dir}/certificate.crt" "$ssl_dir/cert.pem"
    sudo chmod 644 "$ssl_dir/cert.pem"
    
    # Verify created files with openssl
    if ! sudo openssl x509 -in "$ssl_dir/fullchain.pem" -noout -text >/dev/null 2>&1; then
        log_message "ERROR" "fullchain.pem không hợp lệ sau khi tạo"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_message "SUCCESS" "SSL files đã được tạo và validate thành công"
    
    # Copy to archive directory
    sudo cp "$ssl_dir/fullchain.pem" "$archive_dir/fullchain1.pem"
    sudo cp "$ssl_dir/chain.pem" "$archive_dir/chain1.pem"
    sudo cp "$ssl_dir/privkey.pem" "$archive_dir/privkey1.pem"
    sudo cp "$ssl_dir/cert.pem" "$archive_dir/cert1.pem"
    
    # Clean up
    rm -rf "$temp_dir"
    
    # Verify files
    if check_ssl_exists "$domain"; then
        log_message "SUCCESS" "SSL certificates đã được tạo thành công cho: $domain"
        return 0
    else
        log_message "ERROR" "SSL certificates không hợp lệ"
        return 1
    fi
}

# Cài đặt SSL certificate bằng Let's Encrypt/Certbot
install_ssl_with_certbot() {
    local domain="$1"
    local email="$2"
    local provider="${3:-letsencrypt}"  # letsencrypt hoặc zerossl
    
    log_message "INFO" "Cài đặt SSL certificate cho: $domain (Provider: $provider)"
    
    # Đảm bảo certbot đã cài
    if ! install_certbot; then
        return 1
    fi
    
    # Check if certbot is already running
    if pgrep -x "certbot" > /dev/null; then
        log_message "WARN" "Certbot đang chạy, đợi hoàn tất..."
        local wait_count=0
        while pgrep -x "certbot" > /dev/null && [ $wait_count -lt 30 ]; do
            sleep 2
            wait_count=$((wait_count + 1))
        done
        
        # If still running after 60s, kill it
        if pgrep -x "certbot" > /dev/null; then
            log_message "WARN" "Certbot bị treo, đang force kill..."
            pkill -9 certbot 2>/dev/null || true
            sleep 2
        fi
    fi
    
    # Đảm bảo webroot directory tồn tại
    sudo mkdir -p "$WEBROOT_DIR/.well-known/acme-challenge/"
    sudo chown -R www-data:www-data "$WEBROOT_DIR/" 2>/dev/null || true
    sudo chmod -R 755 "$WEBROOT_DIR/"
    
    # Đảm bảo Nginx đang chạy và cấu hình HTTP
    if type apply_nginx_config &>/dev/null; then
        apply_nginx_config "$domain" "true"  # Force HTTP only
    fi
    
    # Đảm bảo Nginx đang chạy
    if ! systemctl is-active --quiet nginx; then
        sudo systemctl start nginx
        sleep 3
    fi
    
    # Prepare certbot command
    local certbot_cmd="certbot certonly --webroot -w $WEBROOT_DIR -d $domain --email $email --agree-tos --non-interactive --no-eff-email"
    
    # Add server URL for ZeroSSL
    if [ "$provider" = "zerossl" ]; then
        certbot_cmd="$certbot_cmd --server https://acme.zerossl.com/v2/DV90"
    fi
    
    # Force renewal to avoid conflicts
    certbot_cmd="$certbot_cmd --force-renewal"
    
    log_message "INFO" "Chạy certbot: $provider"
    
    if sudo $certbot_cmd; then
        if check_ssl_exists "$domain"; then
            log_message "SUCCESS" "SSL certificate đã được cài đặt thành công với $provider"
            
            # Show certificate info
            local cert_expire=$(sudo openssl x509 -enddate -noout -in "$LETSENCRYPT_DIR/live/${domain}/fullchain.pem" 2>/dev/null | cut -d= -f2)
            log_message "INFO" "Certificate expires: $cert_expire"
            
            return 0
        else
            log_message "ERROR" "Certificate files không được tạo"
            return 1
        fi
    else
        log_message "ERROR" "Certbot failed với $provider"
        return 1
    fi
}

# Validate domain format
validate_domain_format() {
    local domain="$1"
    if [ -z "$domain" ]; then
        return 1
    fi
    # IP address pattern
    if [[ "$domain" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    # Domain name pattern
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}

# Cài đặt SSL certificate (unified function)
install_ssl_certificate() {
    local domain="$1"
    local email="${2:-admin@$domain}"
    local force_clean="${3:-false}"
    
    if [ -z "$domain" ]; then
        log_message "ERROR" "Domain không được để trống"
        return 1
    fi
    
    # Validate domain format
    if ! validate_domain_format "$domain"; then
        log_message "ERROR" "Domain format không hợp lệ: $domain"
        return 1
    fi
    
    # Acquire lock
    if ! acquire_ssl_lock; then
        return 1
    fi
    
    log_message "INFO" "Bắt đầu cài đặt SSL certificate cho: $domain"
    
    # Clean old certificates if requested
    if [ "$force_clean" = "true" ]; then
        clean_ssl_certificates "$domain"
    fi
    
    # Kiểm tra xem domain có phải ezn8n.com subdomain không
    if is_ezn8n_subdomain "$domain"; then
        log_message "INFO" "Domain là subdomain của ezn8n.com, download SSL từ drive.inet.vn"
        
        if download_ezn8n_ssl "$domain"; then
            log_message "SUCCESS" "Đã download SSL thành công"
            release_ssl_lock
            return 0
        else
            log_message "WARNING" "Download SSL thất bại, thử Let's Encrypt..."
        fi
    fi
    
    # Try Let's Encrypt first
    log_message "INFO" "Thử cài SSL với Let's Encrypt..."
    if install_ssl_with_certbot "$domain" "$email" "letsencrypt"; then
        release_ssl_lock
        return 0
    fi
    
    # Wait for certbot to finish before trying ZeroSSL
    log_message "INFO" "Đợi certbot hoàn tất..."
    sleep 5
    
    # Kill any hanging certbot processes
    pkill -9 certbot 2>/dev/null || true
    sleep 2
    
    # Try ZeroSSL as fallback
    log_message "INFO" "Let's Encrypt thất bại, thử ZeroSSL..."
    if install_ssl_with_certbot "$domain" "$email" "zerossl"; then
        release_ssl_lock
        return 0
    fi
    
    # All methods failed
    log_message "ERROR" "Tất cả phương thức cài SSL đều thất bại"
    release_ssl_lock
    return 1
}

# Setup auto-renewal cho SSL certificates
setup_ssl_auto_renewal() {
    log_message "INFO" "Thiết lập auto-renewal cho SSL certificates..."
    
    # Create systemd service
    if [ ! -f "/etc/systemd/system/certbot-renewal.service" ]; then
        sudo tee /etc/systemd/system/certbot-renewal.service > /dev/null <<EOF
[Unit]
Description=Certbot Renewal
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --post-hook "systemctl reload nginx"
EOF
        log_message "INFO" "Đã tạo certbot-renewal.service"
    fi
    
    # Create systemd timer
    if [ ! -f "/etc/systemd/system/certbot-renewal.timer" ]; then
        sudo tee /etc/systemd/system/certbot-renewal.timer > /dev/null <<EOF
[Unit]
Description=Run certbot twice daily
Requires=certbot-renewal.service

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
        log_message "INFO" "Đã tạo certbot-renewal.timer"
    fi
    
    # Enable and start timer
    sudo systemctl daemon-reload
    sudo systemctl enable certbot-renewal.timer 2>/dev/null || true
    sudo systemctl start certbot-renewal.timer 2>/dev/null || true
    
    log_message "SUCCESS" "Auto-renewal đã được thiết lập"
    return 0
}

# Renew SSL certificate
renew_ssl_certificate() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        log_message "INFO" "Renew tất cả SSL certificates..."
        if sudo certbot renew; then
            log_message "SUCCESS" "Đã renew SSL certificates"
            return 0
        else
            log_message "ERROR" "Không thể renew SSL certificates"
            return 1
        fi
    else
        log_message "INFO" "Renew SSL certificate cho: $domain"
        if sudo certbot renew --cert-name "$domain"; then
            log_message "SUCCESS" "Đã renew SSL certificate cho: $domain"
            return 0
        else
            log_message "ERROR" "Không thể renew SSL certificate"
            return 1
        fi
    fi
}

# List all SSL certificates
list_ssl_certificates() {
    if ! check_certbot_installed; then
        echo "Certbot chưa được cài đặt"
        return 1
    fi
    
    echo "Danh sách SSL certificates:"
    sudo certbot certificates
}

# Get SSL certificate info
get_ssl_info() {
    local domain="$1"
    
    if [ -z "$domain" ]; then
        log_message "ERROR" "Domain không được để trống"
        return 1
    fi
    
    if ! check_ssl_exists "$domain"; then
        log_message "ERROR" "SSL certificate không tồn tại cho: $domain"
        return 1
    fi
    
    local cert_file="$LETSENCRYPT_DIR/live/${domain}/fullchain.pem"
    
    echo "SSL Certificate Info for: $domain"
    echo "=================================="
    
    # Issuer
    local issuer=$(sudo openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)
    echo "Issuer: $issuer"
    
    # Valid from
    local valid_from=$(sudo openssl x509 -startdate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    echo "Valid from: $valid_from"
    
    # Valid until
    local valid_until=$(sudo openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    echo "Valid until: $valid_until"
    
    # Subject
    local subject=$(sudo openssl x509 -subject -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)
    echo "Subject: $subject"
    
    # Days until expiry
    local days_left=$(( ($(date -d "$valid_until" +%s) - $(date +%s)) / 86400 ))
    echo "Days until expiry: $days_left"
    
    return 0
}

# Hàm wrapper cho Python/webhook
install_ssl_certificate_json() {
    local domain="$1"
    local email="$2"
    local force_clean="${3:-false}"
    
    if install_ssl_certificate "$domain" "$email" "$force_clean"; then
        echo '{"success": true, "message": "SSL certificate installed successfully", "domain": "'"$domain"'"}'
        return 0
    else
        echo '{"success": false, "message": "Failed to install SSL certificate", "domain": "'"$domain"'"}'
        return 1
    fi
}
