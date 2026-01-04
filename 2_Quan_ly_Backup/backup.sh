#!/usr/bin/env bash

# Module Quản lý Backup
# Chứa các hàm liên quan đến backup và restore N8N
source "/opt/n8npanel/v3/common/utils.sh"
source "/opt/n8npanel/v3/common/instance_selector.sh"
source "/opt/n8npanel/v3/common/domain_manager.sh"
N8N_DATA_DIR="/root/n8n_data"
BACKUP_DIR="$N8N_DATA_DIR/backups"

N8N_CONTAINER="${SELECTED_CONTAINER:-n8n}"
POSTGRES_CONTAINER="${SELECTED_POSTGRES:-postgres}"
DOMAIN_CONTAINER="${SELECTED_DOMAIN:-$(get_current_domain 2>/dev/null || echo 'N/A')}"
instance_id="${SELECTED_INSTANCE:-1}"
setup_backup_structure() {
    log_message "INFO" "Thiết lập cấu trúc thư mục backup..."
    
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR/workflows"
    mkdir -p "$BACKUP_DIR/database"
    mkdir -p "$BACKUP_DIR/logs"

    log_message "SUCCESS" "Đã thiết lập cấu trúc backup tại: $BACKUP_DIR"
}

backup_log() {
    local operation="$1"
    local status="$2"
    local details="$3"
    
    # Sử dụng log_message thống nhất thay vì tạo file log riêng
    case $status in
        "START")
            log_message "INFO" "[$operation] Bắt đầu: $details"
            ;;
        "SUCCESS")
            log_message "SUCCESS" "[$operation] Hoàn thành: $details"
            ;;
        "ERROR")
            log_message "ERROR" "[$operation] Lỗi: $details"
            ;;
        "WARNING")
            log_message "WARNING" "[$operation] $details"
            ;;
        *)
            log_message "INFO" "[$operation] $details"
            ;;
    esac
}

create_manual_backup() {
    setup_backup_structure
    log_message "INFO" "🚀 Bắt đầu tạo backup thủ công $DOMAIN_CONTAINER..."
    
    if ! docker ps --format "table {{.Names}}" | grep -q "^${N8N_CONTAINER}$"; then
        log_message "ERROR" "❌ Container $DOMAIN_CONTAINER không đang chạy!"
        return 1
    fi
    
    local has_postgres=false
    if docker ps --format "table {{.Names}}" | grep -q "postgres\|"$POSTGRES_CONTAINER""; then
        has_postgres=true
        log_message "INFO" "✅ Phát hiện "$POSTGRES_CONTAINER" container đang chạy"
    else
        log_message "INFO" "ℹ️ Không tìm thấy "$POSTGRES_CONTAINER" container, sẽ kiểm tra SQLite"
    fi
    
    local temp_dir="/tmp/n8n_backup_"${DOMAIN_CONTAINER}"_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$temp_dir"
    
    local max_retries=5
    local retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if docker inspect -f '{{.State.Running}}' "$N8N_CONTAINER" 2>/dev/null | grep -q true; then
            log_message "INFO" "✅ Container $DOMAIN_CONTAINER đang chạy"
            break
        fi
        retry_count=$((retry_count + 1))
        log_message "WARN" "⏳ Chờ container $DOMAIN_CONTAINER chạy (lần $retry_count/$max_retries)..."
        sleep 2
    done

    if [ $retry_count -eq $max_retries ]; then
        log_message "ERROR" "❌ Container $DOMAIN_CONTAINER không chạy sau $max_retries lần thử"
        return 1
    fi

    # while [ $retry_count -lt $max_retries ]; do
    #     if timeout 10 docker exec "$N8N_CONTAINER" "$N8N_CONTAINER" --version >/dev/null 2>&1; then
    #         log_message "INFO" "✅ Container $DOMAIN_CONTAINER đã sẵn sàng"
    #         break
    #     fi
    #     retry_count=$((retry_count + 1))
    #     log_message "WARN" "⏳ Chờ container $DOMAIN_CONTAINER sẵn sàng (lần thử $retry_count/$max_retries)..."
    #     sleep 2
    # done
    
    # if [ $retry_count -eq $max_retries ]; then
    #     log_message "ERROR" "❌ Container $DOMAIN_CONTAINER không phản hồi sau $max_retries lần thử"
    #     rm -rf "$temp_dir"
    #     return 1
    # fi
    
    log_message "INFO" "📋 Exporting workflows using official $temp_dir CLI..."
    local workflow_exported=false
    local workflow_count=0
    
    docker exec "$N8N_CONTAINER" mkdir -p /tmp/backup_workflows/"$DOMAIN_CONTAINER" 2>/dev/null
    
    if timeout 60 docker exec "$N8N_CONTAINER" n8n export:workflow --backup --output=/tmp/backup_workflows/"$DOMAIN_CONTAINER"/ >/dev/null 2>&1; then
        if docker cp "$N8N_CONTAINER":/tmp/backup_workflows/"$DOMAIN_CONTAINER" "$temp_dir/workflows" >/dev/null 2>&1; then
            mkdir -p "$temp_dir/workflows"
            workflow_count=$(find "$temp_dir/workflows/" -name "*.json" 2>/dev/null | wc -l)
            if [ $workflow_count -gt 0 ]; then
                workflow_exported=true
                log_message "INFO" "✅ Đã export $workflow_count workflows thành công"
            else
                log_message "WARN" "⚠️ Không có workflows nào để export"
                echo "Không có workflows nào trong $DOMAIN_CONTAINER" > "$temp_dir/no_workflows.txt"
            fi
        else
            log_message "ERROR" "❌ Không thể copy workflows từ container"
            echo "Lỗi copy workflows từ container" > "$temp_dir/workflow_export_error.txt"
        fi
    else
        log_message "ERROR" "❌ Lỗi khi export workflows"
        echo "Lỗi export workflows" > "$temp_dir/workflow_export_error.txt"
    fi
    
    docker exec "$N8N_CONTAINER" rm -rf /tmp/backup_workflows/"$DOMAIN_CONTAINER"/ >/dev/null 2>&1
    
    log_message "INFO" "🔐 Exporting credentials using official $DOMAIN_CONTAINER CLI..."
    local credentials_exported=false
    local credentials_count=0
    
    docker exec "$N8N_CONTAINER" mkdir -p /tmp/backup_credentials/"$DOMAIN_CONTAINER" 2>/dev/null
    
    if timeout 60 docker exec "$N8N_CONTAINER" n8n export:credentials --backup --output=/tmp/backup_credentials/"$DOMAIN_CONTAINER"/ >/dev/null 2>&1; then
        if docker cp "$N8N_CONTAINER":/tmp/backup_credentials/"$DOMAIN_CONTAINER"/ "$temp_dir/credentials" >/dev/null 2>&1; then
            mkdir -p "$temp_dir/workflows"
            credentials_count=$(find "$temp_dir/credentials/" -name "*.json" 2>/dev/null | wc -l)
            if [ $credentials_count -gt 0 ]; then
                credentials_exported=true
                log_message "INFO" "✅ Đã export $credentials_count credentials thành công"
            else
                log_message "WARN" "⚠️ Không có credentials nào để export"
                echo "Không có credentials nào trong $DOMAIN_CONTAINER" > "$temp_dir/no_credentials.txt"
            fi
        else
            log_message "ERROR" "❌ Không thể copy credentials từ container"
            echo "Lỗi copy credentials từ container" > "$temp_dir/credentials_export_error.txt"
        fi
    else
        log_message "ERROR" "❌ Lỗi khi export credentials"
        echo "Lỗi export credentials" > "$temp_dir/credentials_export_error.txt"
    fi

    if ! $workflow_exported && ! $credentials_exported; then
        log_message "ERROR" "Không export được workflows và credentials → backup không hợp lệ"
        return 1
    fi

    
    docker exec "$N8N_CONTAINER" rm -rf /tmp/backup_credentials/"$DOMAIN_CONTAINER" >/dev/null 2>&1
    
    log_message "INFO" "🗄️ Backup database..."
    local database_included=false
    local database_type="Unknown"
    
    if [ "$has_postgres" = true ]; then
        database_type="$POSTGRES_CONTAINER"
        log_message "INFO" "📊 Backup "$POSTGRES_CONTAINER" database..."
        
        local db_host=$(docker exec "$N8N_CONTAINER" printenv DB_POSTGRESDB_HOST 2>/dev/null || echo "postgres")
        local db_name=$(docker exec "$N8N_CONTAINER" printenv DB_POSTGRESDB_DATABASE 2>/dev/null || echo "n8n")
        local db_user=$(docker exec "$N8N_CONTAINER" printenv DB_POSTGRESDB_USER 2>/dev/null || echo "n8n")
        
        if docker exec "$POSTGRES_CONTAINER" pg_dump -h localhost -U "$db_user" -d "$db_name" > "$temp_dir/database.sql" 2>/dev/null; then
            database_included=true
            log_message "SUCCESS" "✅ "$POSTGRES_CONTAINER" database backup thành công"
        else
            log_message "WARN" "⚠️ Không thể backup "$POSTGRES_CONTAINER" database"
            echo ""$POSTGRES_CONTAINER" backup failed" > "$temp_dir/database_backup_error.txt"
        fi
    else
        database_type="SQLite"
        log_message "INFO" "📊 Backup SQLite database..."
        
        if docker exec "$N8N_CONTAINER" test -f /home/node/.n8n/database.sqlite 2>/dev/null; then
            if docker cp "$N8N_CONTAINER":/home/node/.n8n/database.sqlite "$temp_dir/database.sqlite" 2>/dev/null; then
                database_included=true
                log_message "SUCCESS" "✅ SQLite database backup thành công"
            else
                log_message "WARN" "⚠️ Không thể copy SQLite database"
            fi
        elif docker exec "$N8N_CONTAINER" test -f /data/database.sqlite 2>/dev/null; then
            if docker cp "$N8N_CONTAINER":/data/database.sqlite "$temp_dir/database.sqlite" 2>/dev/null; then
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
        if docker exec "$N8N_CONTAINER" test -f "$location" 2>/dev/null; then
            if docker cp ""$N8N_CONTAINER":$location" "$temp_dir/encryptionKey" 2>/dev/null; then
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
    docker cp "$N8N_CONTAINER":/home/node/.n8n/config "$temp_dir/config" 2>/dev/null || \
    docker cp "$N8N_CONTAINER":/data/config "$temp_dir/config" 2>/dev/null || \
    echo "No config directory found" > "$temp_dir/no_config.txt"
    
    docker cp "$N8N_CONTAINER":/home/node/.n8n/custom "$temp_dir/custom" 2>/dev/null || \
    docker cp "$N8N_CONTAINER":/data/custom "$temp_dir/custom" 2>/dev/null || \
    echo "No custom nodes found" > "$temp_dir/no_custom_nodes.txt"
    
    log_message "INFO" "📝 Tạo metadata backup..."
    local backup_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local n8n_version=$(docker exec "$N8N_CONTAINER" n8n --version 2>/dev/null | grep -o 'n8n@[0-9.]*' || echo "unknown")
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
    
    local backup_file="$BACKUP_DIR/n8n_backup_"${DOMAIN_CONTAINER}"_$(date +%Y%m%d_%H%M%S).tar.gz"
    
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

list_backups() {
    log_message "INFO" "Đang liệt kê các backup có sẵn..."
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log_message "WARNING" "Thư mục backup không tồn tại: $BACKUP_DIR"
        return 1
    fi
    
    local backup_files=($(find "$BACKUP_DIR" -name "n8n_backup_*.tar.gz" -type f -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        echo "❌ Không tìm thấy backup nào trong $BACKUP_DIR"
        return 1
    fi
    
    echo ""
    echo "📦 ===== DANH SÁCH BACKUP N8N ====="
    echo "🔢 Backup mới nhất có số thứ tự 1"
    echo ""
    printf "%-4s %-25s %-10s %-20s %-12s %-15s %-10s %-10s\n" \
           "STT" "TÊN FILE" "KÍCH THƯỚC" "NGÀY TẠO" "PHIÊN BẢN" "DATABASE" "WORKFLOWS" "CREDENTIALS"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    local counter=1
    for backup_file in "${backup_files[@]}"; do
        if [ -f "$backup_file" ]; then
            local filename=$(basename "$backup_file")
            local filesize=$(du -h "$backup_file" | cut -f1)
            local created_date=$(stat -c %y "$backup_file" | cut -d'.' -f1)
            
            local temp_extract_dir="/tmp/backup_info_extract_$$"
            mkdir -p "$temp_extract_dir"
            
            local n8n_version="N/A"
            local db_type="N/A"
            local workflow_count="N/A"
            local credential_count="N/A"
            
            if tar -tf "$backup_file" backup_info.json >/dev/null 2>&1; then
                tar -xf "$backup_file" -C "$temp_extract_dir" backup_info.json 2>/dev/null
                if [ -f "$temp_extract_dir/backup_info.json" ]; then
                    n8n_version=$(jq -r '.n8n_version // "N/A"' "$temp_extract_dir/backup_info.json" 2>/dev/null)
                    db_type=$(jq -r '.database_type // "N/A"' "$temp_extract_dir/backup_info.json" 2>/dev/null)
                    workflow_count=$(jq -r '.workflows_count // "N/A"' "$temp_extract_dir/backup_info.json" 2>/dev/null)
                    credential_count=$(jq -r '.credentials_count // "N/A"' "$temp_extract_dir/backup_info.json" 2>/dev/null)
                fi
            fi
            
            rm -rf "$temp_extract_dir"
            
            printf "%-4s %-25s %-10s %-20s %-12s %-15s %-10s %-10s\n" \
                   "$counter" "$filename" "$filesize" "$created_date" \
                   "$n8n_version" "$db_type" "$workflow_count" "$credential_count"
            
            counter=$((counter + 1))
        fi
    done
    
    echo ""
    echo "📋 Tổng cộng: $((counter - 1)) backup(s)"
    echo "💡 Backup số 1 là backup mới nhất"
    echo ""
}

select_backup_file() {
    local backup_files=($(find "$BACKUP_DIR" -name "n8n_backup_*.tar.gz" -type f -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        echo "❌ Không có backup nào để chọn"
        return 1
    fi
    
    echo ""
    echo "🔢 Chọn backup để restore (số thứ tự 1 = backup mới nhất):"
    echo ""
    
    local counter=1
    for backup_file in "${backup_files[@]}"; do
        local filename=$(basename "$backup_file")
        local filesize=$(du -h "$backup_file" | cut -f1)
        local created_date=$(stat -c %y "$backup_file" | cut -d'.' -f1)
        
        printf "%2d. %-30s [%s] - %s\n" "$counter" "$filename" "$filesize" "$created_date"
        counter=$((counter + 1))
    done
    
    echo ""
    echo "0. ❌ Hủy bỏ"
    echo ""
    
    while true; do
        read -p "👉 Nhập số thứ tự backup (1-$((counter-1)) hoặc 0 để hủy): " choice
        
        if [ "$choice" = "0" ]; then
            echo "❌ Đã hủy bỏ"
            return 1
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((counter-1)) ]; then
            selected_backup="${backup_files[$((choice-1))]}"
            echo "✅ Đã chọn: $(basename "$selected_backup")"
            return 0
        else
            echo "❌ Lựa chọn không hợp lệ. Vui lòng nhập số từ 1 đến $((counter-1)) hoặc 0 để hủy."
        fi
    done
}

restore_backup() {
    local backup_file="$1"
    if [ -z "$backup_file" ]; then
        select_backup_file
        if [ $? -ne 0 ] || [ -z "$selected_backup" ]; then
            return 1
        fi
        backup_file="$selected_backup"
    fi
    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}❌ File backup không tồn tại: $backup_file${NC}"
        return 1
    fi
    
    echo -e "${CYAN}🔄 KHÔI PHỤC TỪ BACKUP${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${PURPLE}📁 File backup: $(basename "$backup_file")${NC}"
    echo -e "${PURPLE}📏 Dung lượng: $(du -h "$backup_file" | cut -f1)${NC}"
    echo ""
    echo -e "${RED}⚠️  CẢNH BÁO: Quá trình khôi phục sẽ GHI ĐÈ tất cả dữ liệu hiện tại!${NC}"
    echo ""
    while true; do
        read -p "$(echo -e "${RED}Nhập 'Y' để xác nhận hoặc 'N' để hủy: ${NC}")" confirm_input
        confirm_upper=$(echo "$confirm_input" | tr '[:lower:]' '[:upper:]')
        
        if [ "$confirm_upper" = "YES" ] || [ "$confirm_upper" = "Y" ]; then
            echo -e "${GREEN}✅ Đã xác nhận khôi phục${NC}"
            break
        else
            echo -e "${YELLOW}❌ Khôi phục đã bị hủy${NC}"
            return 0
        fi
    done
    if ! docker ps --format "table {{.Names}}" | grep -q "^${N8N_CONTAINER}$"; then
        echo -e "${YELLOW}⚠️ Container $DOMAIN_CONTAINER không đang chạy, đang khởi động...${NC}"
        docker start "$N8N_CONTAINER" >/dev/null 2>&1
        sleep 5
        
        if ! docker ps --format "table {{.Names}}" | grep -q "^${N8N_CONTAINER}$"; then
            echo -e "${RED}❌ Không thể khởi động container "$DOMAIN_CONTAINER"${NC}"
            return 1
        fi
    fi
    
    log_message "INFO" "🚀 Bắt đầu quá trình khôi phục từ: $(basename "$backup_file")"
    log_message "INFO" "🛡️ Tạo backup hiện tại trước khi khôi phục..."
    local pre_restore_backup="$BACKUP_DIR/pre_restore_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    create_manual_backup >/dev/null 2>&1 || log_message "WARN" "Không thể tạo backup trước khôi phục"
    local temp_restore_dir="/tmp/n8n_restore_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$temp_restore_dir"
    
    log_message "INFO" "📦 Giải nén backup..."
    if ! tar -xzf "$backup_file" -C "$temp_restore_dir" 2>/dev/null; then
        log_message "ERROR" "❌ Không thể giải nén backup file"
        rm -rf "$temp_restore_dir"
        return 1
    fi
    
    local backup_content_dir="$temp_restore_dir"
    log_message "INFO" "📋 Khôi phục workflows using official "$DOMAIN_CONTAINER" CLI..."
    local workflow_count=0
    local imported_count=0
    
    if [ -d "$backup_content_dir/workflows" ] && [ "$(ls -A "$backup_content_dir/workflows"/*.json 2>/dev/null)" ]; then
        docker exec "$N8N_CONTAINER" mkdir -p /tmp/restore_workflows 2>/dev/null
        
        for workflow_file in "$backup_content_dir/workflows"/*.json; do
            if [ -f "$workflow_file" ]; then
                workflow_count=$((workflow_count + 1))
                local workflow_name=$(basename "$workflow_file")
                
                log_message "INFO" "Import workflow: $workflow_name"
                if docker cp "$workflow_file" "$N8N_CONTAINER":/tmp/restore_workflows/ 2>/dev/null; then
                    if docker exec "$N8N_CONTAINER" n8n import:workflow --input="/tmp/restore_workflows/$workflow_name" 2>/dev/null; then
                        imported_count=$((imported_count + 1))
                        log_message "SUCCESS" "✅ Đã import: $workflow_name"
                    else
                        log_message "WARN" "⚠️ Không thể import: $workflow_name"
                    fi
                else
                    log_message "WARN" "⚠️ Không thể copy workflow vào container: $workflow_name"
                fi
            fi
        done
        docker exec "$N8N_CONTAINER" rm -rf /tmp/restore_workflows/ 2>/dev/null
        
        log_message "SUCCESS" "✅ Đã khôi phục workflows: $imported_count/$workflow_count"
    else
        log_message "WARN" "⚠️ Không tìm thấy workflows trong backup"
    fi
    local credentials_count=0
    local credentials_imported=0
    
    if [ -d "$backup_content_dir/credentials" ] && [ "$(ls -A "$backup_content_dir/credentials"/*.json 2>/dev/null)" ]; then
        docker exec "$N8N_CONTAINER" mkdir -p /tmp/restore_credentials 2>/dev/null
        
        for credentials_file in "$backup_content_dir/credentials"/*.json; do
            if [ -f "$credentials_file" ]; then
                credentials_count=$((credentials_count + 1))
                local credentials_name=$(basename "$credentials_file")
                
                log_message "INFO" "🔍 Kiểm tra credentials: $credentials_name"
                if ! jq empty "$credentials_file" 2>/dev/null; then
                    log_message "WARN" "⚠️ File không phải JSON hợp lệ: $credentials_name"
                    continue
                fi
                local file_type=$(jq -r 'type' "$credentials_file" 2>/dev/null)
                local temp_import_file="/tmp/temp_import_$credentials_name"
                
                if [ "$file_type" = "array" ]; then
                    cp "$credentials_file" "$temp_import_file"
                elif [ "$file_type" = "object" ]; then
                    log_message "INFO" "🔄 Chuyển đổi object thành array: $credentials_name"
                    jq '[.]' "$credentials_file" > "$temp_import_file" 2>/dev/null
                else
                    log_message "WARN" "⚠️ Format không hỗ trợ: $credentials_name"
                    continue
                fi
                local cred_count=$(jq '. | length' "$temp_import_file" 2>/dev/null || echo "0")
                if [ "$cred_count" -eq 0 ]; then
                    log_message "WARN" "⚠️ File không chứa credentials: $credentials_name"
                    rm -f "$temp_import_file"
                    continue
                fi
                
                log_message "INFO" "📥 Import credentials ($cred_count items): $credentials_name"
                if docker cp "$temp_import_file" "$N8N_CONTAINER":/tmp/restore_credentials/"$credentials_name" 2>/dev/null; then
                    local import_output=$(docker exec "$N8N_CONTAINER" n8n import:credentials --input="/tmp/restore_credentials/$credentials_name" 2>&1)
                    local import_status=$?
                    
                    if [ $import_status -eq 0 ]; then
                        credentials_imported=$((credentials_imported + 1))
                        log_message "SUCCESS" "✅ Đã import thành công: $credentials_name"
                    else
                        log_message "WARN" "⚠️ Lỗi import $credentials_name: $import_output"
                        if [ "$cred_count" -gt 1 ]; then
                            log_message "INFO" "🔄 Thử import từng credential riêng lẻ..."
                            local individual_count=0
                            
                            for i in $(seq 0 $((cred_count - 1))); do
                                local single_cred_file="/tmp/single_cred_${i}_$credentials_name"
                                jq ".[$i] | [.]" "$temp_import_file" > "$single_cred_file" 2>/dev/null
                                
                                if docker cp "$single_cred_file" "$N8N_CONTAINER":/tmp/restore_credentials/ 2>/dev/null; then
                                    if docker exec "$N8N_CONTAINER" n8n import:credentials --input="/tmp/restore_credentials/$(basename "$single_cred_file")" 2>/dev/null; then
                                        individual_count=$((individual_count + 1))
                                    fi
                                fi
                                rm -f "$single_cred_file"
                            done
                            
                            if [ $individual_count -gt 0 ]; then
                                credentials_imported=$((credentials_imported + individual_count))
                                log_message "SUCCESS" "✅ Import riêng lẻ: $individual_count/$cred_count credentials từ $credentials_name"
                            fi
                        fi
                    fi
                else
                    log_message "WARN" "⚠️ Không thể copy credentials vào container: $credentials_name"
                fi
                rm -f "$temp_import_file"
            fi
        done
        docker exec "$N8N_CONTAINER" rm -rf /tmp/restore_credentials/ 2>/dev/null
        
        log_message "SUCCESS" "✅ Đã khôi phục credentials: $credentials_imported/$credentials_count files processed"
    else
        log_message "WARN" "⚠️ Không tìm thấy credentials trong backup"
    fi
    if [ -f "$backup_content_dir/database.sql" ]; then
        log_message "INFO" "🗄️ Khôi phục "$POSTGRES_CONTAINER" database..."
        
        # Lấy thông tin database từ container
        local db_host=$(docker exec "$N8N_CONTAINER" printenv DB_POSTGRESDB_HOST 2>/dev/null || echo "$POSTGRES_CONTAINER")
        local db_name=$(docker exec "$N8N_CONTAINER" printenv DB_POSTGRESDB_DATABASE 2>/dev/null || echo "$N8N_CONTAINER")
        local db_user=$(docker exec "$N8N_CONTAINER" printenv DB_POSTGRESDB_USER 2>/dev/null || echo "$N8N_CONTAINER")
        local db_password=$(docker exec "$N8N_CONTAINER" printenv DB_POSTGRESDB_PASSWORD 2>/dev/null || echo "")
        
        # Kiểm tra xem container postgres có đang chạy không
        if docker ps --format "table {{.Names}}" | grep -q "postgres\|"$POSTGRES_CONTAINER""; then
            log_message "INFO" "Tìm thấy "$POSTGRES_CONTAINER" container, đang restore database..."
            
            # Copy file SQL vào container postgres
            if docker cp "$backup_content_dir/database.sql" "$POSTGRES_CONTAINER":/tmp/restore_database.sql 2>/dev/null; then
                # Drop và tạo lại database (để tránh conflict)
                docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -c "DROP DATABASE IF EXISTS ${db_name}_temp;" 2>/dev/null
                docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -c "CREATE DATABASE ${db_name}_temp;" 2>/dev/null
                
                # Restore vào database tạm
                if docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -d "${db_name}_temp" -f /tmp/restore_database.sql >/dev/null 2>&1; then
                    # Dừng n8n để đổi tên database
                    docker stop "$N8N_CONTAINER" >/dev/null 2>&1
                    sleep 2
                    
                    # Đổi tên database
                    docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -c "DROP DATABASE IF EXISTS ${db_name}_old;" 2>/dev/null
                    docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -c "ALTER DATABASE $db_name RENAME TO ${db_name}_old;" 2>/dev/null
                    docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -c "ALTER DATABASE ${db_name}_temp RENAME TO $db_name;" 2>/dev/null
                    
                    # Khởi động lại n8n
                    docker start "$N8N_CONTAINER" >/dev/null 2>&1
                    
                    log_message "SUCCESS" "✅ Đã khôi phục "$POSTGRES_CONTAINER" database thành công"
                    
                    # Xóa database cũ sau 1 phút (để đảm bảo n8n hoạt động tốt)
                    (sleep 60 && docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -c "DROP DATABASE IF EXISTS ${db_name}_old;" 2>/dev/null) &
                else
                    log_message "ERROR" "❌ Không thể restore "$POSTGRES_CONTAINER" database"
                    docker exec "$POSTGRES_CONTAINER" psql -U "$db_user" -c "DROP DATABASE IF EXISTS ${db_name}_temp;" 2>/dev/null
                fi
                
                # Xóa file SQL tạm
                docker exec "$POSTGRES_CONTAINER" rm -f /tmp/restore_database.sql 2>/dev/null
            else
                log_message "ERROR" "❌ Không thể copy file SQL vào container postgres"
            fi
        else
            log_message "WARN" "⚠️ Không tìm thấy "$POSTGRES_CONTAINER" container đang chạy"
            log_message "INFO" "💡 Để restore thủ công: docker exec -i postgres psql -U $db_user -d $db_name < database.sql"
        fi
    elif [ -f "$backup_content_dir/database.sqlite" ]; then
        log_message "INFO" "🗄️ Khôi phục SQLite database..."
        docker exec "$N8N_CONTAINER" mkdir -p /home/node/.n8n 2>/dev/null
        if docker cp "$backup_content_dir/database.sqlite" "$N8N_CONTAINER":/home/node/.n8n/database.sqlite 2>/dev/null; then
            log_message "SUCCESS" "✅ Đã khôi phục SQLite database"
        else
            log_message "WARN" "⚠️ Không thể khôi phục SQLite database"
        fi
    fi
    if [ -f "$backup_content_dir/encryptionKey" ]; then
        log_message "INFO" "🔑 Khôi phục encryption key..."
        if docker cp "$backup_content_dir/encryptionKey" "$N8N_CONTAINER":/home/node/.n8n/encryptionKey 2>/dev/null || \
           docker cp "$backup_content_dir/encryptionKey" "$N8N_CONTAINER":/data/encryptionKey 2>/dev/null; then
            log_message "SUCCESS" "✅ Đã khôi phục encryption key"
        else
            log_message "WARN" "⚠️ Không thể khôi phục encryption key"
        fi
    fi
    if [ -d "$backup_content_dir/config" ]; then
        docker cp "$backup_content_dir/config" "$N8N_CONTAINER":/home/node/.n8n/ 2>/dev/null || \
        docker cp "$backup_content_dir/config" "$N8N_CONTAINER":/data/ 2>/dev/null
        log_message "INFO" "📁 Đã khôi phục config files"
    fi
    
    if [ -d "$backup_content_dir/custom" ]; then
        docker cp "$backup_content_dir/custom" "$N8N_CONTAINER":/home/node/.n8n/ 2>/dev/null || \
        docker cp "$backup_content_dir/custom" "$N8N_CONTAINER":/data/ 2>/dev/null
        log_message "INFO" "📁 Đã khôi phục custom nodes"
    fi
    if [ -f "$backup_content_dir/backup_info.json" ]; then
        echo -e "\n${CYAN}📋 THÔNG TIN BACKUP:${NC}"
        if command -v jq >/dev/null 2>&1; then
            echo -e "${GREEN}📅 Ngày backup:${NC} $(jq -r '.backup_date // "Không rõ"' "$backup_content_dir/backup_info.json")"
            echo -e "${GREEN}🌐 Domain gốc:${NC} $(jq -r '.domain // "Không rõ"' "$backup_content_dir/backup_info.json")"
            echo -e "${GREEN}📱 IP server gốc:${NC} $(jq -r '.server_ip // "Không rõ"' "$backup_content_dir/backup_info.json")"
            echo -e "${GREEN}🔧 Phiên bản n8n:${NC} $(jq -r '.n8n_version // "Không rõ"' "$backup_content_dir/backup_info.json")"
        else
            echo -e "${YELLOW}Cài đặt jq để xem thông tin chi tiết: apt install jq${NC}"
        fi
    fi
    rm -rf "$temp_restore_dir"
    log_message "INFO" "🔄 Khởi động lại $DOMAIN_CONTAINER container..."
    
    # Sử dụng hàm restart an toàn từ restart_manager (bắt buộc)
    if type safe_restart_n8n &>/dev/null; then
        safe_restart_n8n "true"
    else
        log_message "ERROR" "Module restart_manager chưa được load"
        echo -e "${YELLOW}💡 Vui lòng restart thủ công: docker restart "$N8N_CONTAINER"${NC}"
    fi
    
    # Đọc domain từ source of truth
    local restore_domain=""
    if type get_current_domain &>/dev/null; then
        restore_domain=$(get_current_domain)
    fi
    
    log_message "SUCCESS" "✅ Khôi phục hoàn tất!"
    echo -e "\n${GREEN}✅ QUÁ TRÌNH KHÔI PHỤC HOÀN TẤT!${NC}"
    echo -e "${CYAN}🔗 Truy cập $DOMAIN_CONTAINER tại: ${PURPLE}https://${restore_domain:-localhost}:5678${NC}"
    echo -e "${YELLOW}💡 Lưu ý: Có thể cần vài phút để $DOMAIN_CONTAINER khởi động hoàn tất${NC}"
}

test_restore_functionality() {
    echo -e "${CYAN}🧪 KIỂM TRA TÍNH NĂNG KHÔI PHỤC${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    
    local missing_tools=()
    
    for tool in tar gzip jq docker; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Thiếu các công cụ:${NC} ${missing_tools[*]}"
        echo -e "${CYAN}Cài đặt: ${NC}apt update && apt install -y ${missing_tools[*]}"
    else
        echo -e "${GREEN}✅ Tất cả công cụ cần thiết đều có sẵn${NC}"
    fi
    
    if docker ps >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Docker đang hoạt động${NC}"
    else
        echo -e "${RED}❌ Docker không hoạt động hoặc không có quyền truy cập${NC}"
    fi
    
    if docker ps | grep -q "$N8N_CONTAINER"; then
        echo -e "${GREEN}✅ Container "$N8N_CONTAINER" đang chạy${NC}"
    else
        echo -e "${YELLOW}⚠️  Container "$N8N_CONTAINER" không đang chạy${NC}"
    fi
    
    if [ -d "$N8N_DATA_DIR" ]; then
        echo -e "${GREEN}✅ Thư mục "$N8N_CONTAINER" data tồn tại: $N8N_DATA_DIR${NC}"
    else
        echo -e "${YELLOW}⚠️  Thư mục "$N8N_CONTAINER" data không tồn tại: $N8N_DATA_DIR${NC}"
    fi
    
    if [ -f "$N8N_DATA_DIR/docker-compose.yml" ]; then
        echo -e "${GREEN}✅ File docker-compose.yml tồn tại${NC}"
    else
        echo -e "${YELLOW}⚠️  File docker-compose.yml không tồn tại${NC}"
    fi
    
    local backup_count=0
    if [ -d "$BACKUP_DIR" ]; then
        backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -name 'n8n_backup_*.tar.gz' -type f | wc -l)
    fi
    
    if [ "$backup_count" -gt 0 ]; then
        echo -e "${GREEN}✅ Có $backup_count file backup sẵn sàng${NC}"
    else
        echo -e "${YELLOW}⚠️  Không có file backup nào${NC}"
    fi
}

delete_backup_by_number() {
    log_message "INFO" "Quản lý xóa backup theo số thứ tự..."
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log_message "ERROR" "Thư mục backup không tồn tại: $BACKUP_DIR"
        return 1
    fi
    
    local backup_files=($(find "$BACKUP_DIR" -name "n8n_backup_*.tar.gz" -type f -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        echo -e "${RED}❌ Không tìm thấy backup nào trong $BACKUP_DIR${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${BOLD}${CYAN}🗑️  QUẢN LÝ XÓA BACKUP${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}Hiện tại có ${#backup_files[@]} backup(s) (Giới hạn: 10 backup)${NC}"
    echo ""
    printf "%-4s %-35s %-12s %-25s\n" "STT" "TÊN FILE" "KÍCH THƯỚC" "NGÀY TẠO"
    echo "─────────────────────────────────────────────────────────────────────────────"
    
    local counter=1
    for backup_file in "${backup_files[@]}"; do
        if [ -f "$backup_file" ]; then
            local filename=$(basename "$backup_file")
            local filesize=$(du -h "$backup_file" | cut -f1)
            local created_date=$(stat -c %y "$backup_file" | cut -d'.' -f1 | cut -d' ' -f1,2)
            
            printf "%-4s %-35s %-12s %-25s\n" "$counter" "$filename" "$filesize" "$created_date"
            counter=$((counter + 1))
        fi
    done
    
    echo ""
    echo -e "${BOLD}${PURPLE}TÙY CHỌN XÓA:${NC}"
    echo -e "${CYAN}1. Xóa backup theo số thứ tự cụ thể${NC}"
    echo -e "${CYAN}2. Xóa backup cũ (giữ lại 10 backup mới nhất)${NC}"
    echo -e "${CYAN}3. Xóa tất cả backup (NGUY HIỂM!)${NC}"
    echo -e "${RED}0. Quay lại menu backup${NC}"
    echo ""
    
    read -p "$(echo -e "${BOLD}${CYAN}Chọn tùy chọn [0-3]: ${NC}")" delete_choice
    
    case $delete_choice in
        1)
            echo ""
            read -p "$(echo -e "${CYAN}Nhập số thứ tự backup muốn xóa (1-$((counter-1))): ${NC}")" backup_number
            
            if [[ "$backup_number" =~ ^[0-9]+$ ]] && [ "$backup_number" -ge 1 ] && [ "$backup_number" -le $((counter-1)) ]; then
                local selected_backup="${backup_files[$((backup_number-1))]}"
                local filename=$(basename "$selected_backup")
                
                echo -e "${YELLOW}⚠️  Cảnh báo: Bạn sắp xóa backup:${NC}"
                echo -e "${RED}   File: $filename${NC}"
                echo -e "${RED}   Đường dẫn: $selected_backup${NC}"
                echo ""
                read -p "$(echo -e "${BOLD}${RED}Xác nhận xóa? (y/N): ${NC}")" confirm
                
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    if rm -f "$selected_backup"; then
                        log_message "SUCCESS" "Đã xóa backup: $filename"
                        backup_log "DELETE_SINGLE" "SUCCESS" "Xóa backup #$backup_number: $filename"
                    else
                        log_message "ERROR" "Không thể xóa backup: $filename"
                        backup_log "DELETE_SINGLE" "ERROR" "Lỗi xóa backup #$backup_number: $filename"
                    fi
                else
                    echo -e "${GREEN}✅ Đã hủy xóa backup${NC}"
                fi
            else
                echo -e "${RED}❌ Số thứ tự không hợp lệ!${NC}"
            fi
            ;;
        2)
            if [ ${#backup_files[@]} -le 10 ]; then
                echo -e "${GREEN}✅ Số lượng backup (${#backup_files[@]}) đã ≤ 10. Không cần xóa.${NC}"
            else
                local files_to_delete=$((${#backup_files[@]} - 10))
                echo -e "${YELLOW}⚠️  Sẽ xóa $files_to_delete backup cũ nhất, giữ lại 10 backup mới nhất${NC}"
                echo ""
                read -p "$(echo -e "${BOLD}${RED}Xác nhận xóa $files_to_delete backup cũ? (y/N): ${NC}")" confirm
                
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    local deleted_count=0
                    for ((i=10; i<${#backup_files[@]}; i++)); do
                        if rm -f "${backup_files[$i]}"; then
                            deleted_count=$((deleted_count + 1))
                            log_message "INFO" "Xóa backup cũ: $(basename "${backup_files[$i]}")"
                        fi
                    done
                    
                    log_message "SUCCESS" "Đã xóa $deleted_count backup cũ, giữ lại 10 backup mới nhất"
                    backup_log "CLEANUP_OLD" "SUCCESS" "Xóa $deleted_count backup cũ"
                else
                    echo -e "${GREEN}✅ Đã hủy xóa backup cũ${NC}"
                fi
            fi
            ;;
        3)
            echo -e "${BOLD}${RED}⚠️  CẢNH BÁO NGHIÊM TRỌNG!${NC}"
            echo -e "${RED}Bạn sắp xóa TẤT CẢ ${#backup_files[@]} backup!${NC}"
            echo -e "${RED}Hành động này KHÔNG THỂ HOÀN TÁC!${NC}"
            echo ""
            read -p "$(echo -e "${BOLD}${RED}Gõ 'XOA_TAT_CA' để xác nhận: ${NC}")" confirm
            
            if [ "$confirm" = "XOA_TAT_CA" ]; then
                local deleted_count=0
                for backup_file in "${backup_files[@]}"; do
                    if rm -f "$backup_file"; then
                        deleted_count=$((deleted_count + 1))
                    fi
                done
                
                log_message "WARNING" "Đã xóa TẤT CẢ $deleted_count backup!"
                backup_log "DELETE_ALL" "SUCCESS" "Xóa tất cả $deleted_count backup"
            else
                echo -e "${GREEN}✅ Đã hủy xóa tất cả backup${NC}"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}❌ Tùy chọn không hợp lệ!${NC}"
            ;;
    esac
}

handle_backup_menu() {
    # Chọn instance nếu có nhiều instance
    if type select_instance_for_operation &>/dev/null; then
        if ! select_instance_for_operation "Chọn instance để quản lý backup"; then
            return 0
        fi
        # Cập nhật các biến global cho instance được chọn
        N8N_DATA_DIR="$SELECTED_DATA_DIR"
        BACKUP_DIR="$SELECTED_DATA_DIR/backups"
        COMPOSE_FILE="$SELECTED_COMPOSE_FILE"
    fi
    
    while true; do
        clear
        print_banner
        
        # Hiển thị instance đang làm việc
        local current_instance="${SELECTED_INSTANCE:-1}"
        local current_domain="${SELECTED_DOMAIN:-$(get_current_domain 2>/dev/null || echo 'N/A')}"
        
        echo -e "${BOLD}${CYAN}MENU QUẢN LÝ BACKUP${NC}"
        echo -e "${YELLOW}📌 Instance: ${current_instance} | Domain: ${current_domain}${NC}"
        echo ""
        echo -e "  ${BOLD}${GREEN}TẠO & QUẢN LÝ BACKUP${NC}                ${BOLD}${CYAN}KHÔI PHỤC & XÓA BACKUP${NC}"
        echo ""
        echo -e "  ${BOLD}${GREEN}1.${NC} ${WHITE}Tạo backup thủ công${NC}                ${BOLD}${CYAN}5.${NC} ${WHITE}Liệt kê các bản backup có sẵn${NC}"
        echo -e "  ${BOLD}${GREEN}2.${NC} ${WHITE}Bật backup tự động (cron)${NC}          ${BOLD}${CYAN}6.${NC} ${WHITE}Khôi phục từ backup${NC}"
        echo -e "  ${BOLD}${GREEN}3.${NC} ${WHITE}Tắt backup tự động${NC}                 ${BOLD}${CYAN}7.${NC} ${WHITE}Xóa backup theo số thứ tự${NC}"
        echo -e "  ${BOLD}${GREEN}4.${NC} ${WHITE}Trạng thái backup tự động${NC}          ${BOLD}${CYAN}8.${NC} ${WHITE}Kiểm tra tính năng khôi phục${NC}"
        echo ""
        echo -e "  ${BOLD}${RED}0.${NC} ${WHITE}Quay lại menu chính${NC}"
        
        read -p "$(echo -e "${BOLD}${CYAN}Chọn tùy chọn [0-8]: ${NC}")" backup_choice
        
        case $backup_choice in
            1)
                echo -e "\n${BOLD}${GREEN}🚀 ĐANG TẠO BACKUP...${NC}\n"
                create_manual_backup_for_instance
                ;;
            2)
                echo -e "\n${BOLD}${GREEN}📋 ĐANG BẬT BACKUP TỰ ĐỘNG...${NC}\n"
                enable_cron
                ;;
            3)
                echo -e "\n${BOLD}${GREEN}📋 ĐANG TẮT BACKUP TỰ ĐỘNG...${NC}\n"
                disable_cron
                ;;
            4)
                echo -e "\n${BOLD}${GREEN}📋 ĐANG XEM TRẠNG THÁI BACKUP TỰ ĐỘNG...${NC}\n"
                status_cron
                ;;
            5)
                echo -e "\n${BOLD}${CYAN}📋 DANH SÁCH BACKUP...${NC}\n"
                list_backups
                ;;
            6)
                echo -e "\n${BOLD}${CYAN}📥 KHÔI PHỤC BACKUP...${NC}\n"
                restore_backup
                ;;
            7)
                echo -e "\n${BOLD}${RED}🗑️  XÓA BACKUP THEO STT...${NC}\n"
                delete_backup_by_number
                ;;
            8)
                echo -e "\n${BOLD}${CYAN}🔍 KIỂM TRA TÍNH NĂNG...${NC}\n"
                test_restore_functionality
                ;;
            0)
                break
                ;;
            *)
                echo -e "\n${BOLD}${RED}❌ Tùy chọn không hợp lệ! Vui lòng chọn từ 0-5.${NC}"
                sleep 2
                ;;
        esac
        
        if [ "$backup_choice" != "0" ]; then
            echo ""
            echo -e "${BOLD}${PURPLE}═══════════════════════════════════════════════════════════════════════════════${NC}"
            read -p "$(echo -e "${BOLD}${YELLOW}⏸️  Nhấn Enter để tiếp tục...${NC}")"
        fi
    done
}

# Wrapper function để backup instance được chọn
create_manual_backup_for_instance() {

    export N8N_CONTAINER="${SELECTED_CONTAINER:-n8n}"
    export POSTGRES_CONTAINER="${SELECTED_POSTGRES:-postgres}"
    export DOMAIN_CONTAINER="${SELECTED_DOMAIN:-$(get_current_domain 2>/dev/null || echo 'N/A')}"

    local container_name="${SELECTED_CONTAINER:-n8n}"
    local postgres_name="${SELECTED_POSTGRES:-postgres}"
    local instance_id="${SELECTED_INSTANCE:-1}"

    local current_domain="${SELECTED_DOMAIN:-$(get_current_domain 2>/dev/null || echo 'N/A')}"
    
    log_message "INFO" "🚀 Bắt đầu tạo backup cho instance $instance_id ($current_domain)..."
    
    if ! docker ps --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        log_message "ERROR" "❌ Container $current_domain không đang chạy!"
        return 1
    fi
    
    # Gọi hàm backup gốc với container name đúng
    # Tạm thời override biến để dùng đúng container
    local OLD_CONTAINER="n8n"
    
    # Thực hiện backup với container được chọn
    create_manual_backup
}

# Wrapper function để bật backup tự động instance được chọn
enable_cron() {
    
    local CRON_TIME="*/2 * * * *"

    local current_domain="${SELECTED_DOMAIN:-$(get_current_domain 2>/dev/null || echo 'N/A')}"

    log_message "INFO" "🚀 Bật backup tự động cho instance $instance_id ($container_name)..."

    # Tự nhận đường dẫn script
    local SCRIPT_PATH
    SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

    local LOG_FILE="/var/log/n8n_backup_$(date +%Y%m%d_%H%M%S).log"
 
    CRON_CMD="SELECTED_CONTAINER=$current_domain bash $SCRIPT_PATH manual_backup"

    ( crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH manual_backup"
        echo "$CRON_TIME $CRON_CMD >> $LOG_FILE 2>&1"
    ) | crontab -

    echo "✅ Đã bật backup tự động $current_domain (02:00 mỗi ngày)"
}

# Wrapper function để backup instance được chọn
disable_cron() {


    local current_domain="${SELECTED_DOMAIN:-$(get_current_domain 2>/dev/null || echo 'N/A')}"
    
    log_message "INFO" "🚀 Bắt đầu tắt backup tự động cho instance $instance_id ($current_domain)..."
    CRON_CMD="SELECTED_CONTAINER=$current_domain bash $SCRIPT_PATH"
    
    crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
    echo "🛑 Đã tắt backup tự động"
}

# Wrapper function để backup instance được chọn
status_cron() {
    CRON_CMD="SELECTED_CONTAINER=$current_domain bash $SCRIPT_PATH manual_backup"
    crontab -l | grep "$CRON_CMD" || echo "⚠️ Backup tự động chưa bật"
}

case "$1" in
    manual_backup)
        create_manual_backup_for_instance
    ;;
    enable_cron)
        enable_cron
    ;;
esac
