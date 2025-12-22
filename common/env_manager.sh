#!/usr/bin/env bash

# ENV Manager - Quản lý file .env và migration docker-compose.yml
# Đảm bảo tính nhất quán giữa .env và docker-compose.yml

# Validate domain format
_validate_domain() {
    local domain="$1"
    if [ -z "$domain" ]; then
        return 1
    fi
    # Cho phép IP address hoặc domain name
    if [[ "$domain" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
       [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9\.-]*[a-zA-Z0-9]$ ]] || \
       [[ "$domain" == "localhost" ]]; then
        return 0
    fi
    return 1
}

# Validate và sanitize env value (loại bỏ ký tự nguy hiểm)
_sanitize_env_value() {
    local value="$1"
    # Loại bỏ newlines, carriage returns, và các ký tự đặc biệt nguy hiểm
    echo "$value" | tr -d '\r\n' | sed 's/[;&|`$]//g'
}

# Migrate docker-compose.yml từ giá trị cứng sang biến môi trường
migrate_docker_compose_to_env() {
    local compose_file="$COMPOSE_FILE"
    local migrate_flag="$N8N_DATA_DIR/.migrated_to_env"
    
    if [ ! -f "$compose_file" ]; then
        return 0
    fi
    
    # Kiểm tra đã migrate chưa
    if [ -f "$migrate_flag" ]; then
        return 0
    fi
    
    # Kiểm tra xem docker-compose.yml đã dùng biến chưa
    if grep -q "\${DOMAIN}" "$compose_file" 2>/dev/null && \
       grep -q "\${DB_USER}" "$compose_file" 2>/dev/null && \
       grep -q "\${DB_PASS}" "$compose_file" 2>/dev/null; then
        # Đã dùng biến đầy đủ, đánh dấu đã migrate
        touch "$migrate_flag"
        return 0
    fi
    
    # Kiểm tra xem có giá trị cứng không (cả 2 format: = và :)
    local has_hardcoded_inline=$(grep -E "N8N_HOST=[^$]|POSTGRES_USER=[^$]|POSTGRES_PASSWORD=[^$]" "$compose_file" | grep -v "\${" | wc -l)
    local has_hardcoded_yaml=$(grep -E "POSTGRES_USER:|POSTGRES_PASSWORD:|N8N_HOST:" "$compose_file" | grep -v "\${" | wc -l)
    
    if [ "$has_hardcoded_inline" -eq 0 ] && [ "$has_hardcoded_yaml" -eq 0 ]; then
        # Không có giá trị cứng, không cần migrate
        return 0
    fi
    
    log_message "INFO" "🔄 Phát hiện docker-compose.yml dùng giá trị cứng, đang migrate sang biến môi trường..."
    
    # Backup trước khi migrate
    local backup_file="${compose_file}.backup.migrate.$(date +%Y%m%d_%H%M%S)"
    cp "$compose_file" "$backup_file"
    log_message "INFO" "📦 Đã backup: $backup_file"
    
    # Đọc các giá trị hiện tại (hỗ trợ cả 2 format: = và :)
    # Format 1: - N8N_HOST=value
    # Format 2: N8N_HOST: value
    
    local current_domain=$(grep -E "N8N_HOST[=:]" "$compose_file" | head -1 | sed -E 's/.*N8N_HOST[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
    local current_n8n_user=$(grep -E "N8N_BASIC_AUTH_USER[=:]" "$compose_file" | head -1 | sed -E 's/.*N8N_BASIC_AUTH_USER[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
    local current_n8n_pass=$(grep -E "N8N_BASIC_AUTH_PASSWORD[=:]" "$compose_file" | head -1 | sed -E 's/.*N8N_BASIC_AUTH_PASSWORD[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
    
    # Đọc DB_NAME từ cả POSTGRES_DB và DB_POSTGRESDB_DATABASE
    local current_db_name=$(grep -E "POSTGRES_DB[=:]|DB_POSTGRESDB_DATABASE[=:]" "$compose_file" | head -1 | sed -E 's/.*(POSTGRES_DB|DB_POSTGRESDB_DATABASE)[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
    
    # Đọc DB_USER từ cả POSTGRES_USER và DB_POSTGRESDB_USER
    local current_db_user=$(grep -E "POSTGRES_USER[=:]|DB_POSTGRESDB_USER[=:]" "$compose_file" | head -1 | sed -E 's/.*(POSTGRES_USER|DB_POSTGRESDB_USER)[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
    
    # Đọc DB_PASS từ cả POSTGRES_PASSWORD và DB_POSTGRESDB_PASSWORD
    local current_db_pass=$(grep -E "POSTGRES_PASSWORD[=:]|DB_POSTGRESDB_PASSWORD[=:]" "$compose_file" | head -1 | sed -E 's/.*(POSTGRES_PASSWORD|DB_POSTGRESDB_PASSWORD)[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
    
    log_message "INFO" "📋 Giá trị đọc được:"
    log_message "INFO" "  • DOMAIN: ${current_domain:-"(không tìm thấy)"}"
    log_message "INFO" "  • N8N_USER: ${current_n8n_user:-"(không tìm thấy)"}"
    log_message "INFO" "  • DB_NAME: ${current_db_name:-"(không tìm thấy)"}"
    log_message "INFO" "  • DB_USER: ${current_db_user:-"(không tìm thấy)"}"
    log_message "INFO" "  • DB_PASS: ${current_db_pass:+"***"}"
    
    # Thay thế giá trị cứng bằng biến trong docker-compose.yml
    # Hỗ trợ cả 2 format: = và :
    
    if [ -n "$current_domain" ]; then
        # Format inline: - N8N_HOST=value
        sed -i "s|N8N_HOST=$current_domain|N8N_HOST=\${DOMAIN}|g" "$compose_file"
        sed -i "s|WEBHOOK_URL=https://$current_domain/|WEBHOOK_URL=https://\${DOMAIN}/|g" "$compose_file"
        sed -i "s|N8N_EDITOR_BASE_URL=https://$current_domain/|N8N_EDITOR_BASE_URL=https://\${DOMAIN}/|g" "$compose_file"
        sed -i "s|N8N_PUBLIC_API_HOST=$current_domain|N8N_PUBLIC_API_HOST=\${DOMAIN}|g" "$compose_file"
        sed -i "s|VUE_APP_URL_BASE_API=https://$current_domain/|VUE_APP_URL_BASE_API=https://\${DOMAIN}/|g" "$compose_file"
        
        # Format YAML: N8N_HOST: value
        sed -i "s|N8N_HOST:[[:space:]]*$current_domain|N8N_HOST: \${DOMAIN}|g" "$compose_file"
        sed -i "s|WEBHOOK_URL:[[:space:]]*https://$current_domain/|WEBHOOK_URL: https://\${DOMAIN}/|g" "$compose_file"
        sed -i "s|N8N_EDITOR_BASE_URL:[[:space:]]*https://$current_domain/|N8N_EDITOR_BASE_URL: https://\${DOMAIN}/|g" "$compose_file"
        sed -i "s|N8N_PUBLIC_API_HOST:[[:space:]]*$current_domain|N8N_PUBLIC_API_HOST: \${DOMAIN}|g" "$compose_file"
        sed -i "s|VUE_APP_URL_BASE_API:[[:space:]]*https://$current_domain/|VUE_APP_URL_BASE_API: https://\${DOMAIN}/|g" "$compose_file"
    fi
    
    if [ -n "$current_n8n_user" ]; then
        sed -i "s|N8N_BASIC_AUTH_USER=$current_n8n_user|N8N_BASIC_AUTH_USER=\${N8N_USER}|g" "$compose_file"
        sed -i "s|N8N_BASIC_AUTH_USER:[[:space:]]*$current_n8n_user|N8N_BASIC_AUTH_USER: \${N8N_USER}|g" "$compose_file"
    fi
    
    if [ -n "$current_n8n_pass" ]; then
        sed -i "s|N8N_BASIC_AUTH_PASSWORD=$current_n8n_pass|N8N_BASIC_AUTH_PASSWORD=\${N8N_PASS}|g" "$compose_file"
        sed -i "s|N8N_BASIC_AUTH_PASSWORD:[[:space:]]*$current_n8n_pass|N8N_BASIC_AUTH_PASSWORD: \${N8N_PASS}|g" "$compose_file"
    fi
    
    if [ -n "$current_db_name" ]; then
        sed -i "s|POSTGRES_DB=$current_db_name|POSTGRES_DB=\${DB_NAME}|g" "$compose_file"
        sed -i "s|POSTGRES_DB:[[:space:]]*$current_db_name|POSTGRES_DB: \${DB_NAME}|g" "$compose_file"
        sed -i "s|DB_POSTGRESDB_DATABASE=$current_db_name|DB_POSTGRESDB_DATABASE=\${DB_NAME}|g" "$compose_file"
        sed -i "s|DB_POSTGRESDB_DATABASE:[[:space:]]*$current_db_name|DB_POSTGRESDB_DATABASE: \${DB_NAME}|g" "$compose_file"
    fi
    
    if [ -n "$current_db_user" ]; then
        sed -i "s|POSTGRES_USER=$current_db_user|POSTGRES_USER=\${DB_USER}|g" "$compose_file"
        sed -i "s|POSTGRES_USER:[[:space:]]*$current_db_user|POSTGRES_USER: \${DB_USER}|g" "$compose_file"
        sed -i "s|DB_POSTGRESDB_USER=$current_db_user|DB_POSTGRESDB_USER=\${DB_USER}|g" "$compose_file"
        sed -i "s|DB_POSTGRESDB_USER:[[:space:]]*$current_db_user|DB_POSTGRESDB_USER: \${DB_USER}|g" "$compose_file"
    fi
    
    if [ -n "$current_db_pass" ]; then
        sed -i "s|POSTGRES_PASSWORD=$current_db_pass|POSTGRES_PASSWORD=\${DB_PASS}|g" "$compose_file"
        sed -i "s|POSTGRES_PASSWORD:[[:space:]]*$current_db_pass|POSTGRES_PASSWORD: \${DB_PASS}|g" "$compose_file"
        sed -i "s|DB_POSTGRESDB_PASSWORD=$current_db_pass|DB_POSTGRESDB_PASSWORD=\${DB_PASS}|g" "$compose_file"
        sed -i "s|DB_POSTGRESDB_PASSWORD:[[:space:]]*$current_db_pass|DB_POSTGRESDB_PASSWORD: \${DB_PASS}|g" "$compose_file"
    fi
    
    # Đánh dấu đã migrate
    touch "$migrate_flag"
    
    log_message "SUCCESS" "✅ Đã migrate docker-compose.yml sang dùng biến môi trường"
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║           ✅ ĐÃ MIGRATE DOCKER-COMPOSE.YML THÀNH CÔNG                       ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}📋 Thay đổi:${NC}"
    echo -e "${YELLOW}   • Giá trị cứng → Biến môi trường từ .env${NC}"
    if [ -n "$current_domain" ]; then
        echo -e "${GREEN}   • N8N_HOST: ${current_domain} → \${DOMAIN}${NC}"
    fi
    if [ -n "$current_db_user" ]; then
        echo -e "${GREEN}   • POSTGRES_USER: ${current_db_user} → \${DB_USER}${NC}"
    fi
    if [ -n "$current_db_pass" ]; then
        echo -e "${GREEN}   • POSTGRES_PASSWORD: *** → \${DB_PASS}${NC}"
    fi
    echo ""
    echo -e "${CYAN}📦 Backup gốc:${NC} $backup_file"
    echo -e "${CYAN}💡 Từ giờ mọi thay đổi sẽ qua file .env${NC}"
    echo ""
    
    # Trả về các giá trị đã đọc được để tạo .env
    echo "$current_domain|$current_n8n_user|$current_n8n_pass|$current_db_name|$current_db_user|$current_db_pass"
}

# Đảm bảo file .env tồn tại và đồng bộ với docker-compose.yml
ensure_env_file() {
    local env_file="$N8N_DATA_DIR/.env"
    
    # Nếu không có docker-compose.yml thì không cần làm gì
    if [ ! -f "$COMPOSE_FILE" ]; then
        return 0
    fi
    
    # Bước 1: Migrate docker-compose.yml nếu cần
    local migrated_values=$(migrate_docker_compose_to_env)
    
    # Nếu đã có file .env, kiểm tra xem có đầy đủ biến không
    if [ -f "$env_file" ]; then
        # Kiểm tra các biến bắt buộc
        local has_domain=$(grep -c "^DOMAIN=" "$env_file" 2>/dev/null || echo "0")
        if [ "$has_domain" -gt 0 ]; then
            # File .env đã tồn tại và có DOMAIN, không cần tạo lại
            return 0
        fi
    fi
    
    # Trường hợp 1: Không có file .env hoặc file .env thiếu biến
    # Trường hợp 2: Cài đặt từ image có sẵn (không có .env)
    # => Tạo file .env từ docker-compose.yml hiện tại
    
    log_message "INFO" "Phát hiện thiếu file .env, đang tạo từ docker-compose.yml..."
    
    # Nếu đã migrate, dùng giá trị từ migrate
    local domain=""
    local n8n_user=""
    local n8n_pass=""
    local db_name=""
    local db_user=""
    local db_pass=""
    
    if [ -n "$migrated_values" ]; then
        domain=$(echo "$migrated_values" | cut -d'|' -f1)
        n8n_user=$(echo "$migrated_values" | cut -d'|' -f2)
        n8n_pass=$(echo "$migrated_values" | cut -d'|' -f3)
        db_name=$(echo "$migrated_values" | cut -d'|' -f4)
        db_user=$(echo "$migrated_values" | cut -d'|' -f5)
        db_pass=$(echo "$migrated_values" | cut -d'|' -f6)
        log_message "INFO" "Sử dụng giá trị từ quá trình migrate"
    else
        # Đọc các giá trị từ docker-compose.yml (hỗ trợ cả 2 format: = và :)
        domain=$(grep -E "N8N_HOST[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*N8N_HOST[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}' | sed 's/\${DOMAIN}//g')
        n8n_user=$(grep -E "N8N_BASIC_AUTH_USER[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*N8N_BASIC_AUTH_USER[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}' | sed 's/\${N8N_USER}//g')
        n8n_pass=$(grep -E "N8N_BASIC_AUTH_PASSWORD[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*N8N_BASIC_AUTH_PASSWORD[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}' | sed 's/\${N8N_PASS}//g')
        db_name=$(grep -E "POSTGRES_DB[=:]|DB_POSTGRESDB_DATABASE[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*(POSTGRES_DB|DB_POSTGRESDB_DATABASE)[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}' | sed 's/\${DB_NAME}//g')
        db_user=$(grep -E "POSTGRES_USER[=:]|DB_POSTGRESDB_USER[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*(POSTGRES_USER|DB_POSTGRESDB_USER)[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}' | sed 's/\${DB_USER}//g')
        db_pass=$(grep -E "POSTGRES_PASSWORD[=:]|DB_POSTGRESDB_PASSWORD[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*(POSTGRES_PASSWORD|DB_POSTGRESDB_PASSWORD)[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}' | sed 's/\${DB_PASS}//g')
    fi
    
    # Nếu các giá trị là biến ${...} hoặc rỗng, nghĩa là docker-compose.yml đang dùng .env
    # Nhưng .env không tồn tại => Cần đọc từ container đang chạy
    if [ -z "$domain" ] || [[ "$domain" == *"$"* ]]; then
        if docker ps --format "table {{.Names}}" | grep -q "^n8n$"; then
            domain=$(docker exec n8n printenv N8N_HOST 2>/dev/null | tr -d '\r\n')
            n8n_user=$(docker exec n8n printenv N8N_BASIC_AUTH_USER 2>/dev/null | tr -d '\r\n')
            n8n_pass=$(docker exec n8n printenv N8N_BASIC_AUTH_PASSWORD 2>/dev/null | tr -d '\r\n')
            db_name=$(docker exec n8n printenv DB_POSTGRESDB_DATABASE 2>/dev/null | tr -d '\r\n')
            db_user=$(docker exec n8n printenv DB_POSTGRESDB_USER 2>/dev/null | tr -d '\r\n')
            db_pass=$(docker exec n8n printenv DB_POSTGRESDB_PASSWORD 2>/dev/null | tr -d '\r\n')
            
            log_message "INFO" "Đã đọc config từ container đang chạy"
        else
            log_message "WARNING" "Không thể tạo file .env: container không chạy và không có giá trị trong docker-compose.yml"
            return 1
        fi
    fi
    
    # Validate và sanitize các giá trị trước khi ghi
    domain=$(_sanitize_env_value "$domain")
    n8n_user=$(_sanitize_env_value "${n8n_user:-n8n_admin}")
    n8n_pass=$(_sanitize_env_value "${n8n_pass:-changeme}")
    db_name=$(_sanitize_env_value "${db_name:-n8n}")
    db_user=$(_sanitize_env_value "${db_user:-n8n}")
    db_pass=$(_sanitize_env_value "${db_pass:-changeme}")
    
    # Validate domain format
    if ! _validate_domain "$domain"; then
        log_message "WARNING" "Domain format không hợp lệ: $domain, sử dụng localhost"
        domain="localhost"
    fi
    
    # Tạo file .env
    if [ -n "$domain" ]; then
        cat > "$env_file" <<EOF
DOMAIN=${domain}
N8N_USER=${n8n_user}
N8N_PASS=${n8n_pass}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
EOF
        
        log_message "SUCCESS" "✅ Đã tạo file .env tại: $env_file"
        echo ""
        echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${GREEN}║                  ✅ ĐÃ TẠO FILE .ENV THÀNH CÔNG                             ║${NC}"
        echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}📁 Vị trí:${NC} $env_file"
        echo ""
        echo -e "${CYAN}📋 Nội dung:${NC}"
        echo -e "${GREEN}   • DOMAIN=${domain}${NC}"
        echo -e "${GREEN}   • N8N_USER=${n8n_user:-n8n_admin}${NC}"
        echo -e "${GREEN}   • N8N_PASS=*** (đã ẩn)${NC}"
        echo -e "${GREEN}   • DB_NAME=${db_name:-n8n}${NC}"
        echo -e "${GREEN}   • DB_USER=${db_user:-n8n}${NC}"
        echo -e "${GREEN}   • DB_PASS=*** (đã ẩn)${NC}"
        echo ""
        echo -e "${YELLOW}💡 File .env chứa các biến môi trường cho docker-compose.yml${NC}"
        echo -e "${YELLOW}💡 Từ giờ mọi thay đổi cấu hình sẽ qua file này${NC}"
        echo ""
        return 0
    else
        log_message "ERROR" "Không thể tạo file .env: không tìm thấy thông tin cấu hình"
        return 1
    fi
}

# Load config từ .env hoặc docker-compose.yml
load_config_from_env() {
    local env_file="$N8N_DATA_DIR/.env"
    
    # Ưu tiên đọc từ file .env
    if [ -f "$env_file" ]; then
        if [ -z "$DOMAIN" ]; then
            DOMAIN=$(grep "^DOMAIN=" "$env_file" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d ' ' | tr -d '\r\n')
            if [ -n "$DOMAIN" ]; then
                export DOMAIN
            fi
        fi
        
        if [ -z "$EMAIL" ]; then
            EMAIL=$(grep "^EMAIL=" "$env_file" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d ' ' | tr -d '\r\n')
            if [ -n "$EMAIL" ]; then
                export EMAIL
            fi
        fi
    elif [ -f "$COMPOSE_FILE" ]; then
        # Fallback: Đọc từ docker-compose.yml nếu không có .env (hỗ trợ cả 2 format: = và :)
        if [ -z "$DOMAIN" ]; then
            DOMAIN=$(grep -E "N8N_HOST[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*N8N_HOST[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
            if [ -n "$DOMAIN" ]; then
                export DOMAIN
            fi
        fi
        
        if [ -z "$EMAIL" ]; then
            EMAIL=$(grep -E "N8N_EMAIL[=:]" "$COMPOSE_FILE" | head -1 | sed -E 's/.*N8N_EMAIL[=:][[:space:]]*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
            if [ -n "$EMAIL" ]; then
                export EMAIL
            fi
        fi
    fi
}
