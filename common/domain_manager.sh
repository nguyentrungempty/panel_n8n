#!/usr/bin/env bash

# Domain Manager - Quản lý domain tập trung
# Source of truth: .env file
# Tất cả thao tác domain phải qua module này

readonly DOMAIN_LOCK_FILE="/tmp/n8n_domain_change.lock"
readonly DOMAIN_LOCK_TIMEOUT=300  # 5 phút

# Acquire lock để tránh race condition
acquire_domain_lock() {
    local wait_time=0
    local max_wait=30
    
    while [ -f "$DOMAIN_LOCK_FILE" ]; do
        if [ $wait_time -ge $max_wait ]; then
            log_message "ERROR" "Không thể acquire lock sau ${max_wait}s. Có thể có process khác đang thay đổi domain."
            return 1
        fi
        
        # Kiểm tra xem lock file có quá cũ không (stale lock)
        local lock_age=$(($(date +%s) - $(stat -c %Y "$DOMAIN_LOCK_FILE" 2>/dev/null || echo 0)))
        if [ $lock_age -gt $DOMAIN_LOCK_TIMEOUT ]; then
            log_message "WARNING" "Phát hiện stale lock (${lock_age}s), đang xóa..."
            rm -f "$DOMAIN_LOCK_FILE"
            break
        fi
        
        log_message "INFO" "Đang chờ domain lock... (${wait_time}s)"
        sleep 2
        wait_time=$((wait_time + 2))
    done
    
    # Tạo lock file với PID
    echo "$$" > "$DOMAIN_LOCK_FILE"
    log_message "INFO" "Đã acquire domain lock (PID: $$)"
    return 0
}

# Release lock
release_domain_lock() {
    if [ -f "$DOMAIN_LOCK_FILE" ]; then
        local lock_pid=$(cat "$DOMAIN_LOCK_FILE" 2>/dev/null)
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$DOMAIN_LOCK_FILE"
            log_message "INFO" "Đã release domain lock (PID: $$)"
        fi
    fi
}

# Trap để đảm bảo release lock (chỉ set nếu chưa có trap khác)
# Sử dụng function để có thể gọi từ trap chung
_domain_cleanup() {
    release_domain_lock
}

# Đọc domain hiện tại từ .env (source of truth)
get_current_domain() {
    local env_file="$N8N_DATA_DIR/.env"
    
    if [ ! -f "$env_file" ]; then
        # Fallback: đọc từ container nếu .env không tồn tại
        if docker ps --format "{{.Names}}" | grep -q "^n8n$"; then
            docker exec n8n printenv N8N_HOST 2>/dev/null | tr -d '\r\n'
            return 0
        fi
        return 1
    fi
    
    grep "^DOMAIN=" "$env_file" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d ' ' | tr -d '\r\n'
}

# Cập nhật domain trong .env
update_domain_in_env() {
    local new_domain="$1"
    local env_file="$N8N_DATA_DIR/.env"
    
    if [ -z "$new_domain" ]; then
        log_message "ERROR" "Domain không được để trống"
        return 1
    fi
    
    # Validate domain format
    if ! [[ "$new_domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9\.-]*[a-zA-Z0-9]$ ]]; then
        log_message "ERROR" "Domain format không hợp lệ: $new_domain"
        return 1
    fi
    
    # Đảm bảo .env tồn tại
    if [ ! -f "$env_file" ]; then
        log_message "ERROR" "File .env không tồn tại: $env_file"
        return 1
    fi
    
    # Backup .env trước khi sửa
    local backup_file="${env_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$env_file" "$backup_file"
    log_message "INFO" "Đã backup .env: $backup_file"
    
    # Cập nhật DOMAIN trong .env
    if grep -q "^DOMAIN=" "$env_file"; then
        sed -i "s|^DOMAIN=.*|DOMAIN=$new_domain|" "$env_file"
    else
        echo "DOMAIN=$new_domain" >> "$env_file"
    fi
    
    # Cập nhật EMAIL nếu chưa có (dùng admin@domain)
    if ! grep -q "^EMAIL=" "$env_file"; then
        echo "EMAIL=admin@$new_domain" >> "$env_file"
    fi
    
    log_message "SUCCESS" "Đã cập nhật DOMAIN=$new_domain trong .env"
    
    # Export để các script khác có thể dùng
    export DOMAIN="$new_domain"
    
    return 0
}

# Đảm bảo docker-compose.yml dùng biến từ .env
ensure_compose_uses_env() {
    local compose_file="$COMPOSE_FILE"
    
    if [ ! -f "$compose_file" ]; then
        log_message "ERROR" "File docker-compose.yml không tồn tại"
        return 1
    fi
    
    # Kiểm tra xem đã dùng biến chưa
    if grep -q "\${DOMAIN}" "$compose_file" 2>/dev/null; then
        log_message "INFO" "docker-compose.yml đã dùng biến \${DOMAIN}"
        return 0
    fi
    
    # Nếu chưa, gọi migrate function từ env_manager.sh
    if type migrate_docker_compose_to_env &>/dev/null; then
        log_message "INFO" "Đang migrate docker-compose.yml sang dùng biến môi trường..."
        migrate_docker_compose_to_env
    else
        log_message "WARNING" "Không tìm thấy hàm migrate_docker_compose_to_env"
        return 1
    fi
}

# Restart containers để áp dụng domain mới (sử dụng restart_manager)
restart_containers_for_domain() {
    log_message "INFO" "Đang restart containers để áp dụng domain mới..."
    
    # Sử dụng safe_restart_all từ restart_manager nếu có
    if type safe_restart_all &>/dev/null; then
        safe_restart_all
        return $?
    fi
    
    # Fallback: restart thủ công
    local compose_dir="$N8N_DATA_DIR"
    
    if [ ! -d "$compose_dir" ] || [ ! -f "$compose_dir/docker-compose.yml" ]; then
        log_message "ERROR" "Không tìm thấy docker-compose.yml"
        return 1
    fi
    
    cd "$compose_dir" || return 1
    
    if docker-compose down > /dev/null 2>&1 && docker-compose up -d > /dev/null 2>&1; then
        log_message "SUCCESS" "Đã khởi động lại containers với domain mới"
        sleep 10
        return 0
    else
        log_message "ERROR" "Không thể khởi động lại containers"
        return 1
    fi
}

# Validate email format
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# Hàm chính: Thay đổi domain (được gọi từ mọi nơi)
change_domain_unified() {
    local new_domain="$1"
    local email="${2:-admin@$new_domain}"
    local skip_ssl="${3:-false}"
    local skip_confirmation="${4:-false}"
    
    # Validate domain
    if [ -z "$new_domain" ]; then
        log_message "ERROR" "Domain không được để trống"
        return 1
    fi
    
    # Validate email
    if [ -n "$email" ] && ! validate_email "$email"; then
        log_message "ERROR" "Email format không hợp lệ: $email"
        return 1
    fi
    
    # Kiểm tra container n8n có đang chạy không
    if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^n8n$"; then
        log_message "ERROR" "Container n8n không đang chạy"
        echo -e "${RED}❌ Container n8n cần phải đang chạy để thay đổi domain${NC}"
        return 1
    fi
    
    # Acquire lock
    if ! acquire_domain_lock; then
        return 1
    fi
    
    # Đọc domain hiện tại
    local current_domain=$(get_current_domain)
    
    log_message "INFO" "Bắt đầu thay đổi domain từ '${current_domain:-chưa thiết lập}' sang '$new_domain'"
    
    # Kiểm tra xem domain có thay đổi không
    if [ "$new_domain" = "$current_domain" ]; then
        log_message "WARNING" "Domain mới giống domain hiện tại, không cần thay đổi"
        release_domain_lock
        return 0
    fi
    
    # Xác nhận (nếu không skip)
    # Chỉ hiển thị xác nhận nếu được gọi trực tiếp, không phải từ interactive menu
    if [ "$skip_confirmation" != "true" ] && [ "$skip_confirmation" != "1" ]; then
        echo -e "${YELLOW}═══════════════════════════════════════${NC}"
        echo -e "${YELLOW}Thay đổi domain:${NC}"
        echo -e "${RED}  Từ: ${current_domain:-chưa thiết lập}${NC}"
        echo -e "${GREEN}  Sang: $new_domain${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════${NC}"
        echo ""
        read -p "$(echo -e "${YELLOW}Xác nhận thay đổi? [Y/n]: ${NC}")" confirm
        
        # Enter mặc định là Y
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log_message "INFO" "Người dùng hủy thay đổi domain"
            release_domain_lock
            return 0
        fi
    else
        log_message "INFO" "Bỏ qua xác nhận (skip_confirmation=$skip_confirmation)"
    fi
    
    # Bước 1: Đảm bảo docker-compose.yml dùng biến
    log_message "INFO" "Bước 1/7: Kiểm tra docker-compose.yml..."
    ensure_compose_uses_env
    
    # Bước 2: Cập nhật .env
    log_message "INFO" "Bước 2/7: Cập nhật file .env..."
    if ! update_domain_in_env "$new_domain"; then
        log_message "ERROR" "Không thể cập nhật .env"
        release_domain_lock
        return 1
    fi
    
    # Bước 3: Cập nhật EMAIL nếu cần
    local env_file="$N8N_DATA_DIR/.env"
    if ! grep -q "^EMAIL=" "$env_file"; then
        echo "EMAIL=$email" >> "$env_file"
        log_message "INFO" "Đã thêm EMAIL=$email vào .env"
    fi
    export EMAIL="$email"
    
    # Bước 4: Kiểm tra domain IP (optional)
    log_message "INFO" "Bước 3/7: Kiểm tra domain DNS..."
    if type check_domain_ip &>/dev/null; then
        local server_ipv4=$(type get_server_ipv4 &>/dev/null && get_server_ipv4 || echo "")
        local server_ipv6=$(type get_server_ipv6 &>/dev/null && get_server_ipv6 || echo "")
        
        if ! check_domain_ip "$new_domain" "$server_ipv4" "$server_ipv6"; then
            log_message "WARNING" "Domain chưa trỏ đúng IP, SSL có thể thất bại"
        fi
    fi
    
    # Bước 5: Restart containers
    log_message "INFO" "Bước 4/7: Restart containers..."
    if ! restart_containers_for_domain; then
        log_message "ERROR" "Không thể restart containers"
        release_domain_lock
        return 1
    fi
    
    # Bước 6: Clean SSL cũ của domain cũ (nếu có)
    if [ -n "$current_domain" ] && [ "$current_domain" != "localhost" ] && [ "$current_domain" != "$new_domain" ]; then
        log_message "INFO" "Bước 5/7: Xóa SSL certificate cũ của domain: $current_domain"
        
        if type clean_ssl_certificates &>/dev/null; then
            if clean_ssl_certificates "$current_domain"; then
                log_message "SUCCESS" "Đã xóa SSL certificate cũ"
            else
                log_message "WARN" "Không thể xóa SSL certificate cũ (có thể không tồn tại)"
            fi
        fi
    fi
    
    # Bước 7: Cấu hình Nginx (HTTP only trước)
    log_message "INFO" "Bước 6/7: Cấu hình Nginx..."
    if type apply_nginx_config &>/dev/null; then
        apply_nginx_config "$new_domain" "true"  # HTTP only first
    else
        log_message "WARNING" "Module nginx_manager chưa được load"
    fi
    
    # Bước 8: Cài đặt SSL (nếu không skip)
    if [ "$skip_ssl" != "true" ]; then
        log_message "INFO" "Bước 7/7: Cài đặt SSL certificate..."
        
        # Sử dụng ssl_manager để cài SSL
        if type install_ssl_certificate &>/dev/null; then
            log_message "INFO" "Gọi install_ssl_certificate với domain=$new_domain, email=$email"
            
            if install_ssl_certificate "$new_domain" "$email" "true"; then
                log_message "SUCCESS" "SSL certificate đã được cài đặt thành công"
                
                # Sau khi cài SSL, cập nhật lại Nginx config với SSL
                if type apply_nginx_config &>/dev/null; then
                    log_message "INFO" "Cập nhật Nginx config với SSL..."
                    if apply_nginx_config "$new_domain" "false"; then
                        log_message "SUCCESS" "Nginx đã được cấu hình với SSL"
                    else
                        log_message "ERROR" "Không thể cấu hình Nginx với SSL"
                    fi
                else
                    log_message "ERROR" "Module nginx_manager chưa được load"
                fi
            else
                log_message "ERROR" "Không thể cài đặt SSL certificate"
                log_message "WARNING" "Tiếp tục với HTTP only"
                echo -e "${YELLOW}⚠️  SSL không được cài đặt. Bạn có thể cài thủ công sau bằng menu 'Quản lý SSL'${NC}"
            fi
        else
            log_message "ERROR" "Module ssl_manager chưa được load"
            log_message "WARNING" "Bỏ qua cài SSL"
            echo -e "${YELLOW}⚠️  Module ssl_manager không khả dụng. SSL không được cài đặt.${NC}"
        fi
    else
        log_message "INFO" "Bước 7/7: Bỏ qua cài đặt SSL (theo yêu cầu)"
    fi
    
    # Bước 9: Hoàn tất
    log_message "SUCCESS" "Hoàn tất thay đổi domain!"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  ✅ THAY ĐỔI DOMAIN THÀNH CÔNG                               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}📋 Thông tin:${NC}"
    echo -e "${CYAN}  • Domain cũ: ${RED}${current_domain:-chưa thiết lập}${NC}"
    echo -e "${CYAN}  • Domain mới: ${GREEN}$new_domain${NC}"
    echo -e "${CYAN}  • Email: ${GREEN}$email${NC}"
    echo -e "${CYAN}  • SSL: ${GREEN}$([ "$skip_ssl" = "true" ] && echo "Bỏ qua" || echo "Đã cài đặt")${NC}"
    echo ""
    echo -e "${PURPLE}🔗 Truy cập n8n tại: ${CYAN}https://$new_domain${NC}"
    echo ""
    
    # Release lock
    release_domain_lock
    
    return 0
}

# Hàm wrapper cho Python/webhook (trả về JSON)
change_domain_json() {
    local new_domain="$1"
    local email="$2"
    
    if change_domain_unified "$new_domain" "$email" "false" "true"; then
        echo '{"success": true, "message": "Domain changed successfully", "domain": "'"$new_domain"'"}'
        return 0
    else
        echo '{"success": false, "message": "Failed to change domain", "domain": "'"$new_domain"'"}'
        return 1
    fi
}
