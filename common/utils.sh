#!/usr/bin/env bash

# Common Utilities - Các hàm tiện ích dùng chung

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Sử dụng log file thống nhất cho toàn bộ panel
    local log_dir="${LOG_DIR:-/var/log/n8npanel}"
    local log_file="${LOG_FILE:-$log_dir/n8n_panel.log}"
    local max_log_size=10485760  # 10MB
    
    # Tạo thư mục log nếu chưa có
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    
    # Simple log rotation: nếu file > 10MB, rename và tạo mới
    if [ -f "$log_file" ]; then
        local log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        if [ "$log_size" -gt "$max_log_size" ]; then
            mv "$log_file" "${log_file}.old" 2>/dev/null || true
        fi
    fi
    
    case $level in
        "INFO")
            echo -e "${BLUE}ℹ️  $message${NC}"
            echo "[$timestamp] [INFO] $message" >> "$log_file"
            ;;
        "SUCCESS")
            echo -e "${GREEN}✅ $message${NC}"
            echo "[$timestamp] [SUCCESS] $message" >> "$log_file"
            ;;
        "WARNING"|"WARN")
            echo -e "${YELLOW}⚠️  $message${NC}"
            echo "[$timestamp] [WARNING] $message" >> "$log_file"
            ;;
        "ERROR")
            echo -e "${RED}❌ $message${NC}"
            echo "[$timestamp] [ERROR] $message" >> "$log_file"
            ;;
        *)
            echo -e "${message}"
            echo "[$timestamp] [LOG] $message" >> "$log_file"
            ;;
    esac
}

check_error() {
    local message="$1"
    local action="$2"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Lỗi: $message${NC}"
        if [ "$action" = "exit" ]; then
            exit 1
        else
            return 1
        fi
    fi
}

calculate_ip_sum() {
    local ip=$1
    local sum=0
    
    if [ -z "$ip" ] || ! echo "$ip" | grep -qE "^([0-9]{1,3}\.){3}[0-9]{1,3}$"; then
        echo $((100 + RANDOM % 900))
        return
    fi
    
    for digit in $(echo "$ip" | tr '.' ' '); do
        sum=$((sum + digit))
    done
    
    echo "$sum"
}
