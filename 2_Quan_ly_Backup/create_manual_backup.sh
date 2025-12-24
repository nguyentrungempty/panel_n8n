#!/bin/bash
create_manual_backup() {
    log_message "INFO" "🚀 Bắt đầu tạo backup thủ công..."
    
    if ! docker ps --format "table {{.Names}}" | grep -q "^n8n$"; then
        log_message "ERROR" "❌ Container n8n không đang chạy!"
        return 1
    fi
    
    local has_postgres=false
    if docker ps --format "table {{.Names}}" | grep -q "postgres\|postgresql"; then
        has_postgres=true
        log_message "INFO" "✅ Phát hiện PostgreSQL container đang chạy"
    else
        log_message "INFO" "ℹ️ Không tìm thấy PostgreSQL container, sẽ kiểm tra SQLite"
    fi
    
    local temp_dir="/tmp/n8n_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$temp_dir"
    
    local max_retries=5
    local retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if timeout 10 docker exec n8n n8n --version >/dev/null 2>&1; then
            log_message "INFO" "✅ Container n8n đã sẵn sàng"
            break
        fi
        retry_count=$((retry_count + 1))
        log_message "WARN" "⏳ Chờ container n8n sẵn sàng (lần thử $retry_count/$max_retries)..."
        sleep 2
    done
    
    if [ $retry_count -eq $max_retries ]; then
        log_message "ERROR" "❌ Container n8n không phản hồi sau $max_retries lần thử"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_message "INFO" "📋 Exporting workflows using official n8n CLI..."
    local workflow_exported=false
    local workflow_count=0
    
    docker exec n8n mkdir -p /tmp/backup_workflows 2>/dev/null
    
    if timeout 60 docker exec n8n n8n export:workflow --backup --output=/tmp/backup_workflows/ >/dev/null 2>&1; then
        if docker cp n8n:/tmp/backup_workflows/ "$temp_dir/workflows" >/dev/null 2>&1; then
            workflow_count=$(find "$temp_dir/workflows/" -name "*.json" 2>/dev/null | wc -l)
            if [ $workflow_count -gt 0 ]; then
                workflow_exported=true
                log_message "INFO" "✅ Đã export $workflow_count workflows thành công"
            else
                log_message "WARN" "⚠️ Không có workflows nào để export"
                echo "Không có workflows nào trong n8n" > "$temp_dir/no_workflows.txt"
            fi
        else
            log_message "ERROR" "❌ Không thể copy workflows từ container"
            echo "Lỗi copy workflows từ container" > "$temp_dir/workflow_export_error.txt"
        fi
    else
        log_message "ERROR" "❌ Lỗi khi export workflows"
        echo "Lỗi export workflows" > "$temp_dir/workflow_export_error.txt"
    fi
    
    docker exec n8n rm -rf /tmp/backup_workflows/ >/dev/null 2>&1
    
    log_message "INFO" "🔐 Exporting credentials using official n8n CLI..."
    local credentials_exported=false
    local credentials_count=0
    
    docker exec n8n mkdir -p /tmp/backup_credentials 2>/dev/null
    
    if timeout 60 docker exec n8n n8n export:credentials --backup --output=/tmp/backup_credentials/ >/dev/null 2>&1; then
        if docker cp n8n:/tmp/backup_credentials/ "$temp_dir/credentials" >/dev/null 2>&1; then
            credentials_count=$(find "$temp_dir/credentials/" -name "*.json" 2>/dev/null | wc -l)
            if [ $credentials_count -gt 0 ]; then
                credentials_exported=true
                log_message "INFO" "✅ Đã export $credentials_count credentials thành công"
            else
                log_message "WARN" "⚠️ Không có credentials nào để export"
                echo "Không có credentials nào trong n8n" > "$temp_dir/no_credentials.txt"
            fi
        else
            log_message "ERROR" "❌ Không thể copy credentials từ container"
            echo "Lỗi copy credentials từ container" > "$temp_dir/credentials_export_error.txt"
        fi
    else
        log_message "ERROR" "❌ Lỗi khi export credentials"
        echo "Lỗi export credentials" > "$temp_dir/credentials_export_error.txt"
    fi
    
    docker exec n8n rm -rf /tmp/backup_credentials/ >/dev/null 2>&1
    
    log_message "INFO" "🗄️ Backup database..."
    local database_included=false
    local database_type="Unknown"
    
    if [ "$has_postgres" = true ]; then
        database_type="PostgreSQL"
        log_message "INFO" "📊 Backup PostgreSQL database..."
        
        local db_host=$(docker exec n8n printenv DB_POSTGRESDB_HOST 2>/dev/null || echo "postgres")
        local db_name=$(docker exec n8n printenv DB_POSTGRESDB_DATABASE 2>/dev/null || echo "n8n")
        local db_user=$(docker exec n8n printenv DB_POSTGRESDB_USER 2>/dev/null || echo "n8n")
        
        if docker exec postgres pg_dump -h localhost -U "$db_user" -d "$db_name" > "$temp_dir/database.sql" 2>/dev/null; then
            database_included=true
            log_message "SUCCESS" "✅ PostgreSQL database backup thành công"
        else
            log_message "WARN" "⚠️ Không thể backup PostgreSQL database"
            echo "PostgreSQL backup failed" > "$temp_dir/database_backup_error.txt"
        fi
    else
        database_type="SQLite"
        log_message "INFO" "📊 Backup SQLite database..."
        
        if docker exec n8n test -f /home/node/.n8n/database.sqlite 2>/dev/null; then
            if docker cp n8n:/home/node/.n8n/database.sqlite "$temp_dir/database.sqlite" 2>/dev/null; then
                database_included=true
                log_message "SUCCESS" "✅ SQLite database backup thành công"
            else
                log_message "WARN" "⚠️ Không thể copy SQLite database"
            fi
        elif docker exec n8n test -f /data/database.sqlite 2>/dev/null; then
            if docker cp n8n:/data/database.sqlite "$temp_dir/database.sqlite" 2>/dev/null; then
                database_included=true
                log_message "SUCCESS" "✅ SQLite database backup thành công"
            else
                log_message "WARN" "⚠️ Không thể copy SQLite database"
            fi
        else
            log_message "WARN" "⚠️ Không tìm thấy SQLite database"
            echo "SQLite database not found" > "$temp_dir/no_database.txt"
        fi
    fi
    
    log_message "INFO" "🔑 Tìm kiếm encryption key..."
    local encryption_key_included=false
    local key_locations=(
        "/home/node/.n8n/encryptionKey"
        "/home/node/.n8n/.encryptionKey"
        "/data/encryptionKey"
        "/data/.encryptionKey"
    )
    
    for location in "${key_locations[@]}"; do
        if docker exec n8n test -f "$location" 2>/dev/null; then
            if docker cp "n8n:$location" "$temp_dir/encryptionKey" 2>/dev/null; then
                encryption_key_included=true
                log_message "SUCCESS" "✅ Đã backup encryption key từ: $location"
                break
            fi
        fi
    done
    
    if [ "$encryption_key_included" = false ]; then
        log_message "INFO" "ℹ️ Encryption key chưa được tạo (bình thường nếu chưa setup credentials)"
        echo "Encryption key not found" > "$temp_dir/no_encryption_key.txt"
    fi
    
    log_message "INFO" "📁 Backup config files và custom nodes..."
    docker cp n8n:/home/node/.n8n/config "$temp_dir/config" 2>/dev/null || \
    docker cp n8n:/data/config "$temp_dir/config" 2>/dev/null || \
    echo "No config directory found" > "$temp_dir/no_config.txt"
    
    docker cp n8n:/home/node/.n8n/custom "$temp_dir/custom" 2>/dev/null || \
    docker cp n8n:/data/custom "$temp_dir/custom" 2>/dev/null || \
    echo "No custom nodes found" > "$temp_dir/no_custom_nodes.txt"
    
    log_message "INFO" "📝 Tạo metadata backup..."
    local backup_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local n8n_version=$(docker exec n8n n8n --version 2>/dev/null | grep -o 'n8n@[0-9.]*' || echo "unknown")
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
    
    cat > "$temp_dir/backup_info.json" <<EOF
{
    "backup_date": "$backup_timestamp",
    "backup_format": "official_cli",
    "n8n_version": "$n8n_version",
    "database_type": "$database_type",
    "database_included": $database_included,
    "encryption_key_included": $encryption_key_included,
    "workflows_exported": $workflow_exported,
    "workflows_count": $workflow_count,
    "credentials_exported": $credentials_exported,
    "credentials_count": $credentials_count,
    "domain": "${DOMAIN:-localhost}",
    "server_ip": "$server_ip",
    "backup_method": "docker_official_cli",
    "has_postgres": $has_postgres
}
EOF
    
    local backup_file="$BACKUP_DIR/n8n_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    log_message "INFO" "📦 Tạo file backup..."
    if tar -czf "$backup_file" -C "$temp_dir" . 2>/dev/null; then
        local backup_size=$(du -h "$backup_file" | cut -f1)
        log_message "SUCCESS" "✅ Backup hoàn tất!"
        
        echo -e "\n${GREEN}📦 BACKUP THÀNH CÔNG!${NC}"
        echo -e "${CYAN}📁 File: ${PURPLE}$backup_file${NC}"
        echo -e "${CYAN}📏 Dung lượng: ${PURPLE}$backup_size${NC}"
        echo -e "${CYAN}⏰ Thời gian: ${PURPLE}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo -e "\n${CYAN}📋 NỘI DUNG BACKUP:${NC}"
        echo -e "${GREEN}✅ Workflows: ${NC}$workflow_count (exported: $workflow_exported)"
        echo -e "${GREEN}✅ Credentials: ${NC}$credentials_count (exported: $credentials_exported)"  
        echo -e "${GREEN}✅ Database ($database_type): ${NC}$database_included"
        echo -e "${GREEN}✅ Encryption Key: ${NC}$encryption_key_included"
    else
        log_message "ERROR" "❌ Không thể tạo file backup"
        rm -rf "$temp_dir"
        return 1
    fi
    
    rm -rf "$temp_dir"
    
    log_message "INFO" "🧹 Dọn dẹp backup cũ..."
    find "$BACKUP_DIR" -name "n8n_backup_*.tar.gz" -type f | sort -r | tail -n +11 | xargs rm -f 2>/dev/null || true
    log_message "INFO" "✅ Đã dọn dẹp, giữ lại 10 backup gần nhất"
}