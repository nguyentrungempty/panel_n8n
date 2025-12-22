#!/usr/bin/env bash

# Restart Manager - Quản lý restart container an toàn
# Tránh xung đột khi nhiều thao tác cùng restart container

readonly RESTART_LOCK_FILE="/tmp/n8n_restart.lock"
readonly RESTART_LOCK_TIMEOUT=300  # 5 phút

# Kiểm tra xem container có đang restart không
is_container_restarting() {
    local container_name="$1"
    
    if [ ! -f "$RESTART_LOCK_FILE" ]; then
        return 1  # Không đang restart
    fi
    
    # Kiểm tra lock file có quá cũ không (timeout)
    local lock_age=$(($(date +%s) - $(stat -c %Y "$RESTART_LOCK_FILE" 2>/dev/null || echo 0)))
    if [ $lock_age -gt $RESTART_LOCK_TIMEOUT ]; then
        # Lock file quá cũ, xóa đi
        rm -f "$RESTART_LOCK_FILE"
        return 1
    fi
    
    # Kiểm tra container có thực sự đang restart không
    local container_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    if [ "$container_status" = "restarting" ]; then
        return 0  # Đang restart
    fi
    
    # Container không restart nhưng có lock file, xóa lock
    rm -f "$RESTART_LOCK_FILE"
    return 1
}

# Tạo lock file
create_restart_lock() {
    echo "$(date +%s)" > "$RESTART_LOCK_FILE"
}

# Xóa lock file
remove_restart_lock() {
    rm -f "$RESTART_LOCK_FILE"
}

# Restart container an toàn với lock mechanism
safe_restart_n8n() {
    local wait_for_ready="${1:-true}"  # Mặc định đợi container sẵn sàng
    
    # Kiểm tra xem có đang restart không
    if is_container_restarting "n8n"; then
        log_message "WARNING" "Container n8n đang được restart bởi thao tác khác, vui lòng đợi..."
        
        # Đợi tối đa 60 giây
        local wait_count=0
        while is_container_restarting "n8n" && [ $wait_count -lt 12 ]; do
            sleep 5
            wait_count=$((wait_count + 1))
        done
        
        if is_container_restarting "n8n"; then
            log_message "ERROR" "Timeout khi đợi restart hoàn tất"
            return 1
        fi
        
        log_message "SUCCESS" "Container n8n đã được restart bởi thao tác trước"
        return 0
    fi
    
    # Tạo lock
    create_restart_lock
    
    log_message "INFO" "🔄 Đang restart container n8n..."
    
    # Restart container
    if docker restart n8n >/dev/null 2>&1; then
        log_message "SUCCESS" "✅ Đã gửi lệnh restart thành công"
        
        if [ "$wait_for_ready" = "true" ]; then
            log_message "INFO" "⏳ Đang đợi n8n khởi động..."
            sleep 5
            
            # Đợi container sẵn sàng
            local retry_count=0
            local max_retries=12
            
            while [ $retry_count -lt $max_retries ]; do
                if docker ps --format "{{.Names}}" | grep -q "^n8n$"; then
                    if curl -s -f "http://localhost:5678" >/dev/null 2>&1; then
                        log_message "SUCCESS" "✅ Container n8n đã sẵn sàng"
                        remove_restart_lock
                        return 0
                    fi
                fi
                
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    sleep 5
                fi
            done
            
            log_message "WARNING" "⚠️  Container n8n có thể cần thêm thời gian để khởi động"
        fi
        
        remove_restart_lock
        return 0
    else
        log_message "ERROR" "❌ Không thể restart container n8n"
        remove_restart_lock
        return 1
    fi
}

# Restart container postgres an toàn
safe_restart_postgres() {
    local wait_for_ready="${1:-true}"
    
    if is_container_restarting "postgres"; then
        log_message "WARNING" "Container postgres đang được restart bởi thao tác khác"
        return 1
    fi
    
    create_restart_lock
    
    log_message "INFO" "🔄 Đang restart container postgres..."
    
    if docker restart postgres >/dev/null 2>&1; then
        log_message "SUCCESS" "✅ Đã gửi lệnh restart postgres thành công"
        
        if [ "$wait_for_ready" = "true" ]; then
            log_message "INFO" "⏳ Đang đợi postgres sẵn sàng..."
            sleep 3
            
            # Đọc DB user từ .env hoặc container
            local db_user="postgres"
            local env_file="$N8N_DATA_DIR/.env"
            if [ -f "$env_file" ]; then
                local env_db_user=$(grep "^DB_USER=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d ' ')
                if [ -n "$env_db_user" ]; then
                    db_user="$env_db_user"
                fi
            fi
            
            # Đợi postgres healthy
            local retry_count=0
            local max_retries=12
            
            while [ $retry_count -lt $max_retries ]; do
                if docker ps --format "{{.Names}}" | grep -q "^postgres$"; then
                    # Kiểm tra pg_isready
                    if docker exec postgres pg_isready -U "$db_user" >/dev/null 2>&1; then
                        # Kiểm tra thêm bằng query thực tế
                        if docker exec postgres psql -U "$db_user" -c "SELECT 1" >/dev/null 2>&1; then
                            log_message "SUCCESS" "✅ Container postgres đã sẵn sàng và có thể query"
                            remove_restart_lock
                            return 0
                        fi
                    fi
                fi
                
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    sleep 5
                fi
            done
            
            log_message "WARNING" "⚠️  Container postgres có thể cần thêm thời gian để khởi động"
        fi
        
        remove_restart_lock
        return 0
    else
        log_message "ERROR" "❌ Không thể restart postgres"
        remove_restart_lock
        return 1
    fi
}

# Restart cả 2 containers theo thứ tự an toàn
safe_restart_all() {
    log_message "INFO" "🔄 Đang restart tất cả containers..."
    
    # Restart postgres trước
    if safe_restart_postgres "true"; then
        log_message "INFO" "⏳ Đợi postgres sẵn sàng trước khi restart n8n..."
        
        # Đợi postgres thực sự healthy (không chỉ sleep cứng)
        local db_user="postgres"
        local env_file="$N8N_DATA_DIR/.env"
        if [ -f "$env_file" ]; then
            local env_db_user=$(grep "^DB_USER=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d ' ')
            if [ -n "$env_db_user" ]; then
                db_user="$env_db_user"
            fi
        fi
        
        local retry_count=0
        local max_retries=12
        while [ $retry_count -lt $max_retries ]; do
            if docker exec postgres pg_isready -U "$db_user" >/dev/null 2>&1; then
                log_message "INFO" "✅ Postgres đã sẵn sàng"
                break
            fi
            retry_count=$((retry_count + 1))
            log_message "INFO" "⏳ Đợi postgres... ($retry_count/$max_retries)"
            sleep 3
        done
        
        if [ $retry_count -ge $max_retries ]; then
            log_message "WARNING" "⚠️ Postgres chưa sẵn sàng sau ${max_retries} lần thử, tiếp tục restart n8n..."
        fi
        
        # Sau đó restart n8n
        if safe_restart_n8n "true"; then
            log_message "SUCCESS" "✅ Đã restart tất cả containers thành công"
            return 0
        fi
    fi
    
    log_message "ERROR" "❌ Lỗi khi restart containers"
    return 1
}

