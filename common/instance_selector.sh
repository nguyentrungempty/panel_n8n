#!/usr/bin/env bash

# Instance Selector - Module chọn instance cho multi-instance support
# Tự động detect số lượng instances và cho phép chọn nếu có nhiều hơn 1

# Lấy danh sách tất cả instances đang có
get_all_instances() {
    local instances=()
    
    # Instance 1 (mặc định)
    if [ -d "/root/n8n_data" ] || docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^n8n$"; then
        instances+=("1")
    fi
    
    # Các instance khác (2-10)
    for i in $(seq 2 10); do
        local data_dir="/root/n8n_data_${i}"
        local container_name="n8n_${i}"
        if [ -d "$data_dir" ] || docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
            instances+=("$i")
        fi
    done
    
    echo "${instances[@]}"
}

# Đếm số lượng instances
count_instances() {
    local instances=($(get_all_instances))
    echo "${#instances[@]}"
}

# Lấy domain của instance
get_instance_domain() {
    local instance_id="$1"
    local env_file=""
    
    if [ "$instance_id" = "1" ] || [ -z "$instance_id" ]; then
        env_file="/root/n8n_data/.env"
    else
        env_file="/root/n8n_data_${instance_id}/.env"
    fi
    
    if [ -f "$env_file" ]; then
        grep "^DOMAIN=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'"
    else
        echo "N/A"
    fi
}

# Lấy trạng thái của instance
get_instance_status() {
    local instance_id="$1"
    local container_name="n8n"
    
    if [ "$instance_id" != "1" ]; then
        container_name="n8n_${instance_id}"
    fi
    
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
        echo "✅ Running"
    elif docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
        echo "⏹️ Stopped"
    else
        echo "📁 Data only"
    fi
}

# Lấy data directory của instance
get_instance_data_dir() {
    local instance_id="$1"
    if [ "$instance_id" = "1" ] || [ -z "$instance_id" ]; then
        echo "/root/n8n_data"
    else
        echo "/root/n8n_data_${instance_id}"
    fi
}

# Lấy container name của instance
get_instance_container() {
    local instance_id="$1"
    if [ "$instance_id" = "1" ] || [ -z "$instance_id" ]; then
        echo "n8n"
    else
        echo "n8n_${instance_id}"
    fi
}

# Lấy postgres container name của instance
get_instance_postgres() {
    local instance_id="$1"
    if [ "$instance_id" = "1" ] || [ -z "$instance_id" ]; then
        echo "postgres"
    else
        echo "postgres_${instance_id}"
    fi
}

# Lấy port của instance
get_instance_port() {
    local instance_id="$1"
    if [ "$instance_id" = "1" ] || [ -z "$instance_id" ]; then
        echo "5678"
    else
        echo "$((5678 + instance_id - 1))"
    fi
}

# Hiển thị menu chọn instance và trả về instance_id được chọn
# Nếu chỉ có 1 instance, tự động chọn instance đó
# Return: instance_id (1, 2, 3, ...) hoặc "0" nếu hủy
# LƯU Ý: Dùng >&2 để hiển thị ra màn hình, echo cuối cùng để trả về giá trị
select_instance() {
    local prompt_text="${1:-Chọn instance để thao tác}"
    local instances=($(get_all_instances))
    local count=${#instances[@]}
    
    # Nếu không có instance nào
    if [ $count -eq 0 ]; then
        echo -e "${RED}❌ Không tìm thấy instance N8N nào!${NC}" >&2
        echo -e "${YELLOW}💡 Vui lòng cài đặt N8N trước qua menu 'Cài đặt n8n mới'${NC}" >&2
        echo "0"
        return 1
    fi
    
    # Nếu chỉ có 1 instance, tự động chọn
    if [ $count -eq 1 ]; then
        local single_id="${instances[0]}"
        local single_domain=$(get_instance_domain "$single_id")
        echo -e "${CYAN}📌 Đang sử dụng instance ${single_id} (${single_domain})${NC}" >&2
        echo "$single_id"
        return 0
    fi
    
    # Nếu có nhiều instance, hiển thị menu chọn
    echo "" >&2
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}" >&2
    echo -e "${BOLD}${CYAN}                    CHỌN INSTANCE N8N${NC}" >&2
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}" >&2
    echo "" >&2
    echo -e "${YELLOW}${prompt_text}:${NC}" >&2
    echo "" >&2
    
    # Header
    printf "  ${BOLD}%-4s %-25s %-15s %-8s${NC}\n" "ID" "Domain" "Status" "Port" >&2
    echo "  ────────────────────────────────────────────────────────────" >&2
    
    # Liệt kê các instances
    for id in "${instances[@]}"; do
        local domain=$(get_instance_domain "$id")
        local status=$(get_instance_status "$id")
        local port=$(get_instance_port "$id")
        
        printf "  ${GREEN}%-4s${NC} %-25s %-15s %-8s\n" "$id" "$domain" "$status" "$port" >&2
    done
    
    echo "" >&2
    echo -e "  ${RED}0.${NC} Hủy / Quay lại" >&2
    echo "" >&2
    
    # Nhập lựa chọn
    local selected=""
    while true; do
        read -p "$(echo -e "${BOLD}${CYAN}Nhập ID instance [0-${instances[-1]}]: ${NC}")" selected
        
        # Kiểm tra hủy
        if [ "$selected" = "0" ]; then
            echo "0"
            return 1
        fi
        
        # Kiểm tra ID hợp lệ
        local valid=false
        for id in "${instances[@]}"; do
            if [ "$selected" = "$id" ]; then
                valid=true
                break
            fi
        done
        
        if [ "$valid" = true ]; then
            local sel_domain=$(get_instance_domain "$selected")
            echo -e "${GREEN}✅ Đã chọn instance ${selected} (${sel_domain})${NC}" >&2
            echo "$selected"
            return 0
        else
            echo -e "${RED}❌ ID không hợp lệ! Vui lòng chọn từ danh sách trên.${NC}" >&2
        fi
    done
}

# Wrapper function để sử dụng trong các module khác
# Trả về các biến global: SELECTED_INSTANCE, SELECTED_DATA_DIR, SELECTED_CONTAINER, SELECTED_DOMAIN
select_instance_for_operation() {
    local prompt="${1:-Chọn instance}"
    
    # Gọi select_instance và capture output
    local result
    result=$(select_instance "$prompt")
    local exit_code=$?
    
    # Lấy dòng cuối cùng (instance_id)
    SELECTED_INSTANCE=$(echo "$result" | tail -1)
    
    if [ "$SELECTED_INSTANCE" = "0" ] || [ $exit_code -ne 0 ]; then
        return 1
    fi
    
    # Set các biến liên quan
    SELECTED_DATA_DIR=$(get_instance_data_dir "$SELECTED_INSTANCE")
    SELECTED_CONTAINER=$(get_instance_container "$SELECTED_INSTANCE")
    SELECTED_POSTGRES=$(get_instance_postgres "$SELECTED_INSTANCE")
    SELECTED_DOMAIN=$(get_instance_domain "$SELECTED_INSTANCE")
    SELECTED_PORT=$(get_instance_port "$SELECTED_INSTANCE")
    SELECTED_COMPOSE_FILE="$SELECTED_DATA_DIR/docker-compose.yml"
    SELECTED_ENV_FILE="$SELECTED_DATA_DIR/.env"
    
    # Export để các subshell có thể dùng
    export SELECTED_INSTANCE SELECTED_DATA_DIR SELECTED_CONTAINER SELECTED_POSTGRES
    export SELECTED_DOMAIN SELECTED_PORT SELECTED_COMPOSE_FILE SELECTED_ENV_FILE
    
    return 0
}

# Kiểm tra có phải multi-instance không
is_multi_instance() {
    local count=$(count_instances)
    [ $count -gt 1 ]
}
