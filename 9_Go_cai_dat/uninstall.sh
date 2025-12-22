#!/usr/bin/env bash

# Module Gỡ cài đặt
# Chứa các hàm liên quan đến gỡ cài đặt N8N hoàn toàn

uninstall_n8n() {
    clear
    
    # Kiểm tra có nhiều instance không
    local instance_count=1
    if type count_instances &>/dev/null; then
        instance_count=$(count_instances)
    fi
    
    # Nếu có nhiều instance, hiển thị menu chọn
    if [ "$instance_count" -gt 1 ]; then
        echo -e "${RED}════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}                               MENU GỠ CÀI ĐẶT                                     ${NC}"
        echo -e "${RED}════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${YELLOW}📌 Phát hiện ${instance_count} instances N8N${NC}"
        echo ""
        echo -e "  ${BOLD}${RED}1.${NC} ${WHITE}Gỡ cài đặt instance cụ thể${NC}"
        echo -e "  ${BOLD}${RED}2.${NC} ${WHITE}Gỡ cài đặt TẤT CẢ instances${NC}"
        echo -e "  ${BOLD}${GREEN}0.${NC} ${WHITE}Hủy và quay lại${NC}"
        echo ""
        
        read -p "$(echo -e "${BOLD}${CYAN}Chọn tùy chọn [0-2]: ${NC}")" uninstall_choice
        
        case $uninstall_choice in
            1)
                # Chọn instance để xóa
                if type select_instance_for_operation &>/dev/null; then
                    if ! select_instance_for_operation "Chọn instance để gỡ cài đặt"; then
                        return 0
                    fi
                    
                    # Nếu chọn instance 1, gọi hàm uninstall gốc
                    if [ "$SELECTED_INSTANCE" = "1" ]; then
                        uninstall_instance_1
                    else
                        # Gọi hàm xóa instance từ multi_instance module
                        if type delete_instance &>/dev/null; then
                            delete_instance
                        else
                            echo -e "${RED}❌ Module Multi-Instance chưa được load${NC}"
                        fi
                    fi
                    return 0
                fi
                ;;
            2)
                echo -e "${RED}⚠️  Bạn đã chọn gỡ TẤT CẢ instances!${NC}"
                uninstall_all_instances
                return 0
                ;;
            0|*)
                echo -e "${YELLOW}✅ Đã hủy thao tác gỡ cài đặt.${NC}"
                return 0
                ;;
        esac
    fi
    
    # Nếu chỉ có 1 instance, gỡ instance 1
    uninstall_instance_1
}

# Gỡ cài đặt tất cả instances
uninstall_all_instances() {
    echo -e "${RED}════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}                         GỠ CÀI ĐẶT TẤT CẢ INSTANCES                               ${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Liệt kê tất cả instances
    if type get_all_instances &>/dev/null; then
        local instances=($(get_all_instances))
        echo -e "${YELLOW}Các instances sẽ bị xóa:${NC}"
        for id in "${instances[@]}"; do
            local domain=$(get_instance_domain "$id" 2>/dev/null || echo "N/A")
            echo -e "${RED}   • Instance $id: $domain${NC}"
        done
    fi
    
    echo ""
    echo -e "${RED}⚠️  HÀNH ĐỘNG NÀY KHÔNG THỂ HOÀN TÁC!${NC}"
    echo ""
    
    read -p "$(echo -e "${BOLD}${RED}Nhập 'XOA TAT CA' để xác nhận: ${NC}")" confirm
    if [ "$confirm" != "XOA TAT CA" ]; then
        echo -e "${YELLOW}✅ Đã hủy thao tác.${NC}"
        return 0
    fi
    
    # Xóa từng instance (từ cao xuống thấp để tránh conflict)
    if type get_all_instances &>/dev/null; then
        local instances=($(get_all_instances))
        for id in $(echo "${instances[@]}" | tr ' ' '\n' | sort -rn); do
            echo -e "${CYAN}🗑️  Đang xóa instance $id...${NC}"
            if [ "$id" = "1" ]; then
                uninstall_instance_1_silent
            else
                uninstall_instance_by_id "$id"
            fi
        done
    fi
    
    echo -e "${GREEN}✅ Đã gỡ cài đặt tất cả instances${NC}"
}

# Gỡ cài đặt instance theo ID (không phải instance 1)
uninstall_instance_by_id() {
    local instance_id="$1"
    local data_dir="/root/n8n_data_${instance_id}"
    local container_name="n8n_${instance_id}"
    local db_container="postgres_${instance_id}"
    local domain=$(get_instance_domain "$instance_id" 2>/dev/null)
    
    echo -e "${CYAN}   Dừng containers...${NC}"
    if [ -f "$data_dir/docker-compose.yml" ]; then
        docker-compose -f "$data_dir/docker-compose.yml" down -v 2>/dev/null
    fi
    docker stop "$container_name" "$db_container" 2>/dev/null
    docker rm "$container_name" "$db_container" 2>/dev/null
    
    echo -e "${CYAN}   Xóa volumes...${NC}"
    docker volume rm $(docker volume ls -q | grep -E "n8n_data_${instance_id}|postgres_data_${instance_id}") 2>/dev/null
    
    echo -e "${CYAN}   Xóa thư mục data...${NC}"
    rm -rf "$data_dir"
    
    echo -e "${CYAN}   Xóa Nginx config...${NC}"
    rm -f "/etc/nginx/sites-available/n8n_${instance_id}"
    rm -f "/etc/nginx/sites-enabled/n8n_${instance_id}"
    
    echo -e "${CYAN}   Xóa SSL certificate...${NC}"
    if [ -n "$domain" ]; then
        certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
    fi
    
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    
    echo -e "${GREEN}   ✅ Đã xóa instance $instance_id${NC}"
}

# Gỡ cài đặt instance 1 (silent mode cho batch)
uninstall_instance_1_silent() {
    N8N_DATA_DIR="/root/n8n_data"
    BACKUP_DIR="$N8N_DATA_DIR/backups"
    
    docker stop n8n postgres 2>/dev/null
    docker rm n8n postgres 2>/dev/null
    docker volume rm n8n_data postgres_data n8n_data_postgres_data n8n_data_n8n_data 2>/dev/null
    docker network rm n8n-network 2>/dev/null
    rm -rf "$N8N_DATA_DIR"
    rm -f /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    
    echo -e "${GREEN}   ✅ Đã xóa instance 1${NC}"
}

# Gỡ cài đặt instance 1 (với xác nhận)
uninstall_instance_1() {
    echo -e "${RED}════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}                               CẢNH BÁO GỠ CÀI ĐẶT                                ${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${RED}⚠️  HÀNH ĐỘNG NÀY KHÔNG THỂ HOÀN TÁC!${NC}"
    echo -e "\n${YELLOW}Các thành phần sẽ bị xóa:${NC}"
    echo -e "${RED}   • Docker containers (n8n, postgres)${NC}"
    echo -e "${RED}   • Docker volumes (dữ liệu n8n, database)${NC}"
    echo -e "${RED}   • Docker networks${NC}"
    echo -e "${RED}   • Thư mục dữ liệu ($N8N_DATA_DIR)${NC}"
    echo -e "${RED}   • Thư mục backup ($BACKUP_DIR)${NC}"
    echo -e "${RED}   • Cấu hình Nginx${NC}"
    echo -e "${RED}   • SSL certificates${NC}"
    echo -e "${RED}   • Docker images (n8n, postgres)${NC}"
    echo ""
    
    while true; do
        echo -e "${BOLD}${RED}Nhập 'XACNHAN' để gỡ hoặc 'HUY' để hủy thao tác:${NC}"
        read -p "$(echo -e "${CYAN}> ${NC}")" confirm_input
        
        if [ "$confirm_input" = "XACNHAN" ]; then
            break
        elif [ "$confirm_input" = "HUY" ] || [ -z "$confirm_input" ]; then
            echo -e "${YELLOW}✅ Đã hủy thao tác gỡ cài đặt.${NC}"
            return 0
        else
            echo -e "${RED}❌ Vui lòng nhập chính xác 'XACNHAN' hoặc 'HUY' để hủy${NC}"
            continue
        fi
    done
    
    log_message "INFO" "🔄 Bắt đầu gỡ cài đặt N8N..."
    
    echo -e "\n${YELLOW}🔄 Đang thực hiện gỡ cài đặt...${NC}"
    echo ""
    
    # Bước 1: Tạo backup cuối cùng
    echo -e "${BOLD}${CYAN}📦 Bước 1/9: Tạo backup cuối cùng...${NC}"
    if [ -d "$N8N_DATA_DIR" ] && [ -f "$N8N_DATA_DIR/docker-compose.yml" ]; then
        if type setup_backup_structure &>/dev/null && type create_manual_backup &>/dev/null; then
            setup_backup_structure
            create_manual_backup || true
            echo -e "${GREEN}   ✅ Đã tạo backup cuối cùng${NC}"
        else
            echo -e "${YELLOW}   ⚠️  Module backup chưa được load, bỏ qua backup${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠️  Không tìm thấy cài đặt N8N, bỏ qua backup${NC}"
    fi
    
    # Bước 2: Dừng containers
    echo ""
    echo -e "${BOLD}${CYAN}⏹️  Bước 2/9: Dừng containers...${NC}"
    if command -v docker &> /dev/null; then
        docker stop n8n postgres 2>/dev/null || true
        echo -e "${GREEN}   ✅ Đã dừng containers${NC}"
        log_message "INFO" "Đã dừng containers"
    else
        echo -e "${YELLOW}   ⚠️  Docker không có sẵn${NC}"
    fi
    
    # Bước 3: Xóa containers
    echo ""
    echo -e "${BOLD}${CYAN}🗑️  Bước 3/9: Xóa containers...${NC}"
    if command -v docker &> /dev/null; then
        docker rm n8n postgres 2>/dev/null || true
        echo -e "${GREEN}   ✅ Đã xóa containers${NC}"
        log_message "INFO" "Đã xóa containers"
    else
        echo -e "${YELLOW}   ⚠️  Docker không có sẵn${NC}"
    fi
    
    # Bước 4: Xóa Docker volumes
    echo ""
    echo -e "${BOLD}${CYAN}💾 Bước 4/9: Xóa Docker volumes...${NC}"
    if command -v docker &> /dev/null; then
        docker volume rm n8n_data postgres_data n8n_data_postgres_data 2>/dev/null || true
        
        local volumes=$(docker volume ls -q 2>/dev/null | grep -E "n8n|postgres" || true)
        if [ -n "$volumes" ]; then
            echo "$volumes" | xargs docker volume rm 2>/dev/null || true
        fi
        
        docker volume prune -f 2>/dev/null || true
        echo -e "${GREEN}   ✅ Đã xóa volumes${NC}"
        log_message "INFO" "Đã xóa volumes"
    else
        echo -e "${YELLOW}   ⚠️  Docker không có sẵn${NC}"
    fi
    
    # Bước 5: Xóa Docker networks
    echo ""
    echo -e "${BOLD}${CYAN}🌐 Bước 5/9: Xóa Docker networks...${NC}"
    if command -v docker &> /dev/null; then
        docker network rm n8n-network 2>/dev/null || true
        
        local networks=$(docker network ls --format "{{.Name}}" 2>/dev/null | grep -i "n8n" || true)
        if [ -n "$networks" ]; then
            echo "$networks" | xargs docker network rm 2>/dev/null || true
        fi
        
        docker network prune -f 2>/dev/null || true
        echo -e "${GREEN}   ✅ Đã xóa networks${NC}"
        log_message "INFO" "Đã xóa networks"
    else
        echo -e "${YELLOW}   ⚠️  Docker không có sẵn${NC}"
    fi
    
    # Bước 6: Xóa thư mục dữ liệu
    echo ""
    echo -e "${BOLD}${CYAN}📁 Bước 6/9: Xóa thư mục dữ liệu...${NC}"
    if [ -d "$N8N_DATA_DIR" ]; then
        rm -rf "$N8N_DATA_DIR"
        echo -e "${GREEN}   ✅ Đã xóa thư mục $N8N_DATA_DIR${NC}"
        log_message "INFO" "Đã xóa thư mục $N8N_DATA_DIR"
    else
        echo -e "${YELLOW}   ⚠️  Thư mục không tồn tại${NC}"
    fi
    
    # Bước 7: Xóa cấu hình Nginx
    echo ""
    echo -e "${BOLD}${CYAN}🌐 Bước 7/9: Xóa cấu hình Nginx...${NC}"
    if [ -f "/etc/nginx/sites-available/n8n" ]; then
        sudo rm -f /etc/nginx/sites-available/n8n
        sudo rm -f /etc/nginx/sites-enabled/n8n
        
        if systemctl is-active --quiet nginx; then
            sudo systemctl reload nginx 2>/dev/null || true
        fi
        
        echo -e "${GREEN}   ✅ Đã xóa cấu hình Nginx${NC}"
        log_message "INFO" "Đã xóa cấu hình Nginx"
    else
        echo -e "${YELLOW}   ⚠️  Cấu hình Nginx không tồn tại${NC}"
    fi
    
    # Bước 8: Xóa SSL certificates
    echo ""
    echo -e "${BOLD}${CYAN}🔒 Bước 8/9: Xóa SSL certificates...${NC}"
    if [ -d "/etc/letsencrypt/live" ]; then
        local cert_found=false
        
        find /etc/letsencrypt/live -maxdepth 1 -type d 2>/dev/null | while read cert_dir; do
            local domain_name=$(basename "$cert_dir")
            
            if [ "$domain_name" != "live" ] && [ "$domain_name" != "." ]; then
                echo -e "${CYAN}   • Xóa SSL certificate cho: $domain_name${NC}"
                sudo certbot delete --cert-name "$domain_name" --non-interactive 2>/dev/null || true
                cert_found=true
            fi
        done
        
        if [ "$cert_found" = true ]; then
            echo -e "${GREEN}   ✅ Đã xóa SSL certificates${NC}"
        else
            echo -e "${YELLOW}   ⚠️  Không tìm thấy SSL certificates${NC}"
        fi
    else
        echo -e "${YELLOW}   ⚠️  Thư mục SSL không tồn tại${NC}"
    fi
    
    # Bước 9: Xóa Docker images
    echo ""
    echo -e "${BOLD}${CYAN}🐳 Bước 9/9: Xóa Docker images...${NC}"
    if command -v docker &> /dev/null; then
        local images_removed=0
        
        # Xóa n8n images
        local n8n_images=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "n8nio/n8n" || true)
        if [ -n "$n8n_images" ]; then
            echo "$n8n_images" | while read image; do
                if [ -n "$image" ]; then
                    echo -e "${CYAN}   • Xóa image: $image${NC}"
                    docker rmi "$image" 2>/dev/null || true
                    images_removed=$((images_removed + 1))
                fi
            done
        fi
        
        # Xóa postgres images
        local postgres_images=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "^postgres:" || true)
        if [ -n "$postgres_images" ]; then
            echo "$postgres_images" | while read image; do
                if [ -n "$image" ]; then
                    echo -e "${CYAN}   • Xóa image: $image${NC}"
                    docker rmi "$image" 2>/dev/null || true
                    images_removed=$((images_removed + 1))
                fi
            done
        fi
        
        # Dọn dẹp Docker system
        docker system prune -f 2>/dev/null || true
        
        echo -e "${GREEN}   ✅ Đã xóa Docker images và dọn dẹp system${NC}"
    else
        echo -e "${YELLOW}   ⚠️  Docker không có sẵn${NC}"
    fi
    
    log_message "SUCCESS" "Hoàn tất gỡ cài đặt N8N"
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                          ✅ GỠ CÀI ĐẶT HOÀN TẤT THÀNH CÔNG! ✅                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}💡 Lưu ý:${NC}"
    echo -e "${WHITE}   • Docker vẫn được giữ lại trên hệ thống${NC}"
    echo -e "${WHITE}   • Nginx vẫn được giữ lại trên hệ thống${NC}"
    echo -e "${WHITE}   • Backup cuối cùng đã được lưu (nếu có)${NC}"
    echo ""
}
