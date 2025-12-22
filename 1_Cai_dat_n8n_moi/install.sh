#!/usr/bin/env bash

# Module cài đặt N8N
# Chứa các hàm riêng cho quá trình cài đặt N8N mới
# Các hàm common (network, nginx, utils) được load từ thư mục common/

configure_timezone() {
    echo -e "${YELLOW}Đang cấu hình múi giờ GMT+7 (Hồ Chí Minh)...${NC}"
    
    current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
    
    if [ "$current_timezone" = "Asia/Ho_Chi_Minh" ]; then
        echo -e "${GREEN}Múi giờ đã được cài đặt thành Asia/Ho_Chi_Minh.${NC}"
    else
        if ! sudo timedatectl set-timezone Asia/Ho_Chi_Minh; then
            echo -e "${RED}❌ Không thể cài đặt múi giờ cho hệ thống${NC}"
            return 1
        fi
        echo -e "${GREEN}Múi giờ hiện tại: $(timedatectl | grep "Time zone")${NC}"
    fi
}

install_dependencies() {
    echo -e "${YELLOW}Đang cài đặt các gói cần thiết...${NC}"
    local packages=("nginx" "curl" "ca-certificates" "gnupg")
    local need_update=false
    
    for pkg in "${packages[@]}"; do
        if ! command -v $pkg &> /dev/null; then
            need_update=true
            echo -e "${CYAN}Cần cài đặt: $pkg${NC}"
        else
            echo -e "${GREEN}$pkg đã được cài đặt.${NC}"
        fi
    done
    
    if [ "$need_update" = true ]; then
        echo -e "${CYAN}Cập nhật và cài đặt các gói cần thiết...${NC}"
        if ! sudo apt update || ! sudo apt install -y "${packages[@]}"; then
            echo -e "${RED}❌ Không thể cài đặt các gói cần thiết${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}Cài đặt các gói cần thiết thành công!${NC}"
}

check_previous_installation() {
    local reinstall=false
    local found_components=()
    
    echo -e "${YELLOW}Đang kiểm tra cài đặt trước đó...${NC}"
    
    if command -v docker &> /dev/null && docker info &>/dev/null 2>&1; then
        local containers_check=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -E "^(n8n|postgres)$" || true)
        if [ -n "$containers_check" ]; then
            echo -e "${CYAN}Phát hiện Docker containers: $containers_check${NC}"
            found_components+=("containers")
            reinstall=true
        fi
    fi
    
    if [ -f "/etc/nginx/sites-available/n8n" ]; then
        echo -e "${CYAN}Phát hiện cấu hình Nginx cho n8n.${NC}"
        found_components+=("nginx-config")
        reinstall=true
    fi
    
    if [ -d "$HOME/n8n_data" ]; then
        if [ -f "$HOME/n8n_data/docker-compose.yml" ] || [ -d "$HOME/n8n_data/.n8n" ]; then
            echo -e "${CYAN}Phát hiện thư mục dữ liệu n8n với nội dung.${NC}"
            found_components+=("data-directory")
            reinstall=true
        fi
    fi
    
    if [ "$reinstall" = true ]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                            PHÁT HIỆN CÀI ĐẶT TRƯỚC ĐÓ                                ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        
        echo -e "\n${YELLOW}🔍 Các thành phần được phát hiện:${NC}"
        for component in "${found_components[@]}"; do
            case $component in
                "containers") echo -e "${RED}   • Docker containers (n8n/postgres)${NC}" ;;
                "nginx-config") echo -e "${RED}   • Cấu hình Nginx${NC}" ;;
                "data-directory") echo -e "${RED}   • Thư mục dữ liệu n8n${NC}" ;;
            esac
        done
        
        echo -e "\n${RED}⚠️  Để tránh lỗi cài đặt, cần xóa sạch các thành phần trên.${NC}"
        echo -e "\n${YELLOW}📋 Lựa chọn của bạn:${NC}"
        echo -e "${CYAN}1. Xóa sạch và cài đặt mới${NC}"
        echo -e "${CYAN}2. Hủy cài đặt${NC}"
        
        while true; do
            read -p "$(echo -e ${CYAN}Nhập lựa chọn [1/2]: ${NC})" reinstall_choice
            case $reinstall_choice in
                1) 
                    echo -e "${YELLOW}✅ Đã chọn xóa sạch và cài đặt mới.${NC}"
                    
                    # Gọi hàm uninstall nếu có
                    if type uninstall_n8n &>/dev/null; then
                        echo -e "${CYAN}🔄 Đang gỡ cài đặt cũ...${NC}"
                        uninstall_n8n
                    else
                        # Xóa thủ công nếu không có module uninstall
                        echo -e "${CYAN}🔄 Đang xóa cài đặt cũ...${NC}"
                        docker stop n8n postgres 2>/dev/null || true
                        docker rm n8n postgres 2>/dev/null || true
                        docker volume rm n8n_data postgres_data 2>/dev/null || true
                        rm -rf "$HOME/n8n_data" 2>/dev/null || true
                        rm -f /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n 2>/dev/null || true
                        systemctl reload nginx 2>/dev/null || true
                        echo -e "${GREEN}✅ Đã xóa cài đặt cũ${NC}"
                    fi
                    break
                    ;;
                2|"") 
                    echo -e "${RED}❌ Đã hủy quá trình cài đặt.${NC}"
                    return 1
                    ;;
                *) 
                    echo -e "${RED}❌ Vui lòng chọn 1 hoặc 2${NC}"
                    continue
                    ;;
            esac
        done
    else
        echo -e "${GREEN}✅ Không phát hiện cài đặt trước đó. Tiến hành cài đặt mới...${NC}"
    fi
    
    return 0
}

install_docker() {
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}Docker đã được cài đặt.${NC}"
        if ! systemctl is-active --quiet docker; then
            echo -e "${YELLOW}Docker đã cài đặt nhưng không chạy. Đang khởi động Docker...${NC}"
            if ! sudo systemctl start docker || ! sudo systemctl enable docker; then
                echo -e "${RED}❌ Không thể khởi động Docker${NC}"
                return 1
            fi
        else 
            echo -e "${GREEN}Docker đang chạy.${NC}"
        fi
    else
        echo -e "${YELLOW}Đang cài đặt Docker và Docker Compose...${NC}"
        sudo apt update
        sudo apt install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt update
        if ! sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
            echo -e "${RED}❌ Không thể cài đặt Docker${NC}"
            return 1
        fi
        
        if ! sudo curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose; then
            echo -e "${RED}❌ Không thể tải Docker Compose${NC}"
            return 1
        fi
        sudo chmod +x /usr/local/bin/docker-compose
        
        sudo systemctl enable docker
        sudo systemctl start docker
    fi
    
    echo -e "${CYAN}Đang chờ Docker khởi động...${NC}"
    timeout 30s bash -c 'until sudo docker info &>/dev/null; do echo -e "\033[0;36mĐang chờ Docker khởi động...\033[0m"; sleep 2; done'
    
    if sudo docker info &>/dev/null; then
        echo -e "${GREEN}Docker và Docker Compose đã sẵn sàng!${NC}"
    else
        echo -e "${RED}❌ Docker không khởi động được${NC}"
        return 1
    fi
    
    local ipv6=$(get_server_ipv6)
    if [ -n "$ipv6" ]; then
        echo -e "\n${CYAN}🌐 Phát hiện IPv6: $ipv6${NC}"
        echo -e "${CYAN}📝 Đang cấu hình Docker hỗ trợ IPv6...${NC}"
        
        sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80",
  "experimental": true,
  "ip6tables": true
}
EOF
        
        echo -e "${GREEN}✅ Đã tạo cấu hình Docker IPv6${NC}"
        echo -e "${CYAN}🔧 Đang bật IPv6 forwarding...${NC}"
        
        sudo sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
        sudo sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1
        
        if ! grep -q "net.ipv6.conf.all.forwarding" /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv6.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf >/dev/null
            echo "net.ipv6.conf.default.forwarding=1" | sudo tee -a /etc/sysctl.conf >/dev/null
        fi
        
        echo -e "${GREEN}✅ IPv6 forwarding đã được bật${NC}"
        echo -e "${CYAN}🔄 Khởi động lại Docker để áp dụng IPv6...${NC}"
        sudo systemctl restart docker
        sleep 3
        
        echo -e "${GREEN}✅ Hoàn tất cấu hình IPv6 cho Docker${NC}\n"
        log_message "SUCCESS" "Đã cấu hình Docker với IPv6 support: $ipv6"
    else
        echo -e "${YELLOW}ℹ️  Server chỉ có IPv4, cấu hình Docker với IPv4 only${NC}"
        log_message "INFO" "Server IPv4 only, không cần cấu hình Docker IPv6"
    fi
}

configure_n8n() {
    echo -e "${YELLOW}Đang cấu hình n8n...${NC}"
    mkdir -p ~/n8n_data
    
    if ! cd ~/n8n_data; then
        echo -e "${RED}❌ Không thể chuyển vào thư mục n8n_data${NC}"
        return 1
    fi
    
    # Kiểm tra IPv6
    local ipv6=$(get_server_ipv6)
    local has_ipv6=false
    
    if [ -n "$ipv6" ]; then
        has_ipv6=true
        echo -e "${CYAN}🌐 Phát hiện IPv6: $ipv6 - Sẽ cấu hình Docker với dual-stack${NC}"
        log_message "INFO" "Cấu hình Docker network với IPv6 support: $ipv6"
    else
        echo -e "${CYAN}🌐 Server chỉ có IPv4 - Sẽ cấu hình Docker với IPv4 only${NC}"
        log_message "INFO" "Cấu hình Docker network với IPv4 only"
    fi
    
    echo -e "${CYAN}Tạo file docker-compose.yml...${NC}"
    
    if [ "$has_ipv6" = true ]; then
        # Docker-compose với IPv6 support (dual-stack)
        cat > docker-compose.yml <<EOL
services:
  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: \${DB_USER}
      POSTGRES_PASSWORD: \${DB_PASS}
      POSTGRES_DB: \${DB_NAME}
      TZ: Asia/Ho_Chi_Minh
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${DB_USER} -d \${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: postgres -c 'timezone=Asia/Ho_Chi_Minh'
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_PASS}
      - N8N_RUNNERS_ENABLED=true
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${DB_NAME}
      - DB_POSTGRESDB_USER=\${DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_PASS}
      - N8N_HOST=\${DOMAIN}
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://\${DOMAIN}/
      - N8N_EDITOR_BASE_URL=https://\${DOMAIN}/
      - N8N_PUBLIC_API_HOST=\${DOMAIN}
      - VUE_APP_URL_BASE_API=https://\${DOMAIN}/
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - TZ=Asia/Ho_Chi_Minh
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1
        - subnet: fd00:a8a8::/64
          gateway: fd00:a8a8::1

volumes:
  postgres_data:
  n8n_data:
EOL
    else
        # Docker-compose với IPv4 only
        cat > docker-compose.yml <<EOL
services:
  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: \${DB_USER}
      POSTGRES_PASSWORD: \${DB_PASS}
      POSTGRES_DB: \${DB_NAME}
      TZ: Asia/Ho_Chi_Minh
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${DB_USER} -d \${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: postgres -c 'timezone=Asia/Ho_Chi_Minh'
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_PASS}
      - N8N_RUNNERS_ENABLED=true
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${DB_NAME}
      - DB_POSTGRESDB_USER=\${DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_PASS}
      - N8N_HOST=\${DOMAIN}
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://\${DOMAIN}/
      - N8N_EDITOR_BASE_URL=https://\${DOMAIN}/
      - N8N_PUBLIC_API_HOST=\${DOMAIN}
      - VUE_APP_URL_BASE_API=https://\${DOMAIN}/
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - TZ=Asia/Ho_Chi_Minh
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - n8n-network

networks:
  n8n-network:
    driver: bridge
    enable_ipv6: false
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1

volumes:
  postgres_data:
  n8n_data:
EOL
    fi

    echo -e "${CYAN}Tạo file .env...${NC}"
    cat > .env <<EOL
DOMAIN=${DOMAIN}
N8N_USER=${N8N_USER}
N8N_PASS=${N8N_PASS}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOL

    echo -e "${CYAN}📥 Pull image mới nhất từ Docker Hub...${NC}"
    sudo docker-compose pull
    
    echo -e "${CYAN}Khởi chạy PostgreSQL...${NC}"
    if ! sudo docker-compose up -d postgres; then
        echo -e "${RED}Không thể khởi chạy PostgreSQL${NC}"
        return 1
    fi
    
    echo -e "${CYAN}Đợi PostgreSQL khởi động hoàn tất...${NC}"
    sleep 10
    
    echo -e "${CYAN}Khởi chạy n8n...${NC}"
    if ! sudo docker-compose up -d n8n; then
        echo -e "${RED}Không thể khởi chạy n8n${NC}"
        return 1
    fi
    
    echo -e "${CYAN}Đang chờ n8n container khởi động...${NC}"
    timeout 60s bash -c 'until sudo docker ps | grep -q n8n; do echo -e "\033[0;36mĐang chờ n8n container khởi động...\033[0m"; sleep 5; done'
    
    if docker ps | grep -q "n8n"; then
        echo -e "${GREEN}Cấu hình n8n thành công!${NC}"
    else
        echo -e "${RED}n8n container không chạy${NC}"
        return 1
    fi
}

configure_nginx() {
    echo -e "${YELLOW}Đang cấu hình Nginx...${NC}"
    
    # Sử dụng nginx_manager để cấu hình
    if type apply_nginx_config &>/dev/null; then
        log_message "INFO" "Cấu hình Nginx qua nginx_manager"
        if apply_nginx_config "$DOMAIN" "true"; then
            echo -e "${GREEN}Cấu hình Nginx thành công!${NC}"
            return 0
        else
            echo -e "${RED}Không thể cấu hình Nginx${NC}"
            return 1
        fi
    else
        echo -e "${RED}Module nginx_manager chưa được load${NC}"
        return 1
    fi
}

check_n8n_health() {
    echo -e "${YELLOW}Kiểm tra n8n hoạt động...${NC}"
    sleep 10
    
    if docker ps | grep -q "n8n"; then
        echo -e "${GREEN}n8n container đang chạy.${NC}"
    else
        echo -e "${RED}n8n container không chạy.${NC}"
    fi
}

show_installation_summary() {
    clear
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                           🎉 CÀI ĐẶT HOÀN TẤT THÀNH CÔNG! 🎉                          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    
    echo -e "\n${CYAN}📋 THÔNG TIN HỆ THỐNG:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}🌐 Domain:${NC} https://${DOMAIN}"
    echo -e "${GREEN}👤 n8n User:${NC} ${N8N_USER}"
    echo -e "${GREEN}🔑 n8n Pass:${NC} ${N8N_PASS}"
    echo -e "${GREEN}🗄️  PostgreSQL DB:${NC} ${DB_NAME}"
    echo -e "${GREEN}👤 PostgreSQL User:${NC} ${DB_USER}"
    echo -e "${GREEN}🔑 PostgreSQL Pass:${NC} ${DB_PASS}"
    echo -e "${GREEN}⏰ Múi giờ:${NC} Asia/Ho_Chi_Minh (GMT+7)"
    
    echo -e "\n${CYAN}🎛️  QUẢN LÝ HỆ THỐNG:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${YELLOW}• Xem logs: ${CYAN}docker logs n8n${NC}"
    echo -e "${YELLOW}• Khởi động lại: ${CYAN}docker restart n8n${NC}"
    echo -e "${YELLOW}• Thư mục dữ liệu: ${CYAN}$N8N_DATA_DIR${NC}"
    
    echo -e "\n${PURPLE}🔗 Truy cập n8n tại: ${CYAN}https://${DOMAIN}${NC}"
    echo -e "${YELLOW}💡 SSL chưa được cài đặt. Bạn có thể cài đặt SSL sau bằng menu 'Quản lý SSL' (option 3).${NC}"
    echo ""
}

main_installation() {
    print_banner
    echo ""
    
    # Kiểm tra xem đã có instance 1 chưa
    local has_instance_1=false
    if [ -d "/root/n8n_data" ] && [ -f "/root/n8n_data/docker-compose.yml" ]; then
        has_instance_1=true
    fi
    
    # Nếu đã có instance 1, hỏi người dùng muốn làm gì
    if [ "$has_instance_1" = true ]; then
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                         PHÁT HIỆN N8N ĐÃ ĐƯỢC CÀI ĐẶT                                ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}Bạn muốn làm gì?${NC}"
        echo ""
        echo -e "  ${BOLD}${GREEN}1.${NC} ${WHITE}Cài đặt lại instance 1 (xóa dữ liệu cũ)${NC}"
        echo -e "  ${BOLD}${PURPLE}2.${NC} ${WHITE}Tạo thêm instance mới (Multi-Instance)${NC}"
        echo -e "  ${BOLD}${RED}0.${NC} ${WHITE}Hủy và quay lại${NC}"
        echo ""
        
        read -p "$(echo -e "${BOLD}${CYAN}Chọn tùy chọn [0-2]: ${NC}")" install_choice
        
        case $install_choice in
            1)
                echo -e "${YELLOW}⚠️  Bạn đã chọn cài đặt lại. Dữ liệu cũ sẽ bị xóa!${NC}"
                ;;
            2)
                echo -e "${GREEN}✅ Chuyển sang tạo instance mới...${NC}"
                if type handle_multi_instance_menu &>/dev/null; then
                    # Gọi trực tiếp hàm tạo instance mới
                    if type create_new_instance &>/dev/null; then
                        create_new_instance
                    else
                        handle_multi_instance_menu
                    fi
                else
                    echo -e "${RED}❌ Module Multi-Instance chưa được load${NC}"
                fi
                return 0
                ;;
            0|*)
                echo -e "${YELLOW}📋 Quay lại menu chính...${NC}"
                return 0
                ;;
        esac
    fi
    
    IP_DETECT_RESULT=$(auto_detect_ips)
    IP_TYPE=$(echo "$IP_DETECT_RESULT" | tail -1 | cut -d'|' -f1)
    SERVER_IPV4=$(echo "$IP_DETECT_RESULT" | tail -1 | cut -d'|' -f3)
    SERVER_IPV6=$(echo "$IP_DETECT_RESULT" | tail -1 | cut -d'|' -f4)
    
    if [ -n "$SERVER_IPV4" ]; then
        SERVER_IP="$SERVER_IPV4"
    else
        SERVER_IP="$SERVER_IPV6"
    fi
    
    if [ "$IP_TYPE" = "ipv4|ipv6" ]; then
        log_message "INFO" "IP máy chủ: IPv4=$SERVER_IPV4, IPv6=$SERVER_IPV6 (Dual-stack)"
    elif [ "$IP_TYPE" = "ipv4" ]; then
        log_message "INFO" "IP máy chủ: $SERVER_IPV4 (IPv4 only)"
    elif [ "$IP_TYPE" = "ipv6" ]; then
        log_message "INFO" "IP máy chủ: $SERVER_IPV6 (IPv6 only)"
    else
        log_message "ERROR" "Không phát hiện được IP nào"
        echo -e "${RED}❌ Không thể phát hiện địa chỉ IP của máy chủ. Vui lòng kiểm tra kết nối mạng.${NC}"
        return 1
    fi
    
    IP_SUM=$(calculate_ip_sum "$SERVER_IPV4")
    
    if [ -z "$SERVER_IPV4" ]; then
        echo -e "${YELLOW}💡 Không có IPv4, sử dụng số ngẫu nhiên cho cấu hình: $IP_SUM${NC}"
    fi
    
    echo ""
    if ! check_previous_installation; then
        echo -e "${YELLOW}📋 Quay lại menu chính...${NC}"
        return
    fi
    
    echo -e "${PURPLE}📝 Vui lòng nhập các thông tin cấu hình:${NC}"
    while true; do
        read -p "$(echo -e ${CYAN}Nhập domain của bạn: ${NC})" DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}Domain không được để trống.${NC}"
            continue
        fi
        break
    done
    
    echo -e "${PURPLE}⚙️  Chọn chế độ cài đặt:${NC}"
    echo -e "${CYAN}1. Chạy thủ công (nhập thông tin)${NC}"
    echo -e "${CYAN}2. Chạy tự động (tự động tạo thông tin)${NC}"
    read -p "$(echo -e ${CYAN}Lựa chọn của bạn [1/2]: ${NC})" setup_mode
    
    if [ "$setup_mode" = "1" ]; then
        echo -e "${YELLOW}📝 Bạn đã chọn chế độ cài đặt thủ công.${NC}"
        read -p "$(echo -e ${CYAN}Nhập email của bạn: ${NC})" EMAIL
        read -p "$(echo -e ${CYAN}Nhập n8n user: ${NC})" N8N_USER
        read -s -p "$(echo -e ${CYAN}Nhập n8n password: ${NC})" N8N_PASS
        echo
        read -p "$(echo -e ${CYAN}Nhập tên database: ${NC})" DB_NAME
        read -p "$(echo -e ${CYAN}Nhập user database: ${NC})" DB_USER
        read -s -p "$(echo -e ${CYAN}Nhập mật khẩu database: ${NC})" DB_PASS
        echo
    else
        echo -e "${YELLOW}🤖 Bạn đã chọn chế độ cài đặt tự động.${NC}"
        
        EMAIL="admin@$DOMAIN"
        N8N_USER="n8n_inet$IP_SUM"
        N8N_PASS="n8n_inet$IP_SUM"
        DB_NAME="n8n_inet$IP_SUM"
        DB_USER="n8n_inet$IP_SUM"
        DB_PASS="n8n_inet$IP_SUM"
        
        echo -e "${GREEN}✅ Thông tin tự động:${NC}"
        echo -e "${CYAN}Email:${NC} $EMAIL"
        echo -e "${CYAN}n8n User/Pass:${NC} $N8N_USER"
        echo -e "${CYAN}Database name/user/pass:${NC} $DB_NAME"
    fi
    
    if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$N8N_USER" || -z "$N8N_PASS" || -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
        log_message "ERROR" "Vui lòng cung cấp tất cả thông tin cần thiết"
        return 1
    fi
    
    echo -e "\n${PURPLE}🚀 Bắt đầu quá trình cài đặt...${NC}\n"
    
    if ! configure_timezone; then
        echo -e "${RED}❌ Lỗi cài đặt múi giờ. Quay lại menu chính...${NC}"
        return 1
    fi
    
    if ! install_dependencies; then
        echo -e "${RED}❌ Lỗi cài đặt dependencies. Quay lại menu chính...${NC}"
        return 1
    fi
    
    if ! install_docker; then
        echo -e "${RED}❌ Lỗi cài đặt Docker. Quay lại menu chính...${NC}"
        return 1
    fi
    
    if ! configure_n8n; then
        echo -e "${RED}❌ Lỗi cấu hình n8n. Quay lại menu chính...${NC}"
        return 1
    fi
    
    if ! configure_nginx; then
        echo -e "${RED}❌ Lỗi cấu hình Nginx. Quay lại menu chính...${NC}"
        return 1
    fi
    
    check_n8n_health
    show_installation_summary
}
