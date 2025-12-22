#!/usr/bin/env bash

# Module Quản lý Phiên bản N8N
# Cho phép kiểm tra, liệt kê và chọn phiên bản n8n cụ thể

# Số lượng phiên bản hiển thị mặc định
DEFAULT_VERSION_LIMIT=20

# Lấy phiên bản n8n hiện tại đang chạy
get_current_n8n_version() {
    local container="${1:-n8n}"
    
    if ! docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        echo ""
        return 1
    fi
    
    local version=$(docker exec "$container" n8n --version 2>/dev/null | tr -d '\r\n')
    echo "$version"
}

# Lấy phiên bản từ docker image đang sử dụng
get_current_image_version() {
    local container="${1:-n8n}"
    
    local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
    if [ -z "$image" ]; then
        echo ""
        return 1
    fi
    
    local tag=$(echo "$image" | cut -d':' -f2)
    if [ "$tag" = "$image" ] || [ "$tag" = "latest" ]; then
        get_current_n8n_version "$container"
    else
        echo "$tag"
    fi
}

# So sánh 2 phiên bản (semver)
# Return: 0 nếu v1 > v2, 1 nếu v1 < v2, 2 nếu v1 = v2
compare_versions() {
    local v1="$1"
    local v2="$2"
    
    v1=$(echo "$v1" | sed 's/^v//')
    v2=$(echo "$v2" | sed 's/^v//')
    
    if [ "$v1" = "$v2" ]; then
        return 2
    fi
    
    local v1_major=$(echo "$v1" | cut -d'.' -f1)
    local v1_minor=$(echo "$v1" | cut -d'.' -f2)
    local v1_patch=$(echo "$v1" | cut -d'.' -f3)
    
    local v2_major=$(echo "$v2" | cut -d'.' -f1)
    local v2_minor=$(echo "$v2" | cut -d'.' -f2)
    local v2_patch=$(echo "$v2" | cut -d'.' -f3)
    
    v1_major=${v1_major:-0}
    v1_minor=${v1_minor:-0}
    v1_patch=${v1_patch:-0}
    v2_major=${v2_major:-0}
    v2_minor=${v2_minor:-0}
    v2_patch=${v2_patch:-0}
    
    if [ "$v1_major" -gt "$v2_major" ] 2>/dev/null; then
        return 0
    elif [ "$v1_major" -lt "$v2_major" ] 2>/dev/null; then
        return 1
    fi
    
    if [ "$v1_minor" -gt "$v2_minor" ] 2>/dev/null; then
        return 0
    elif [ "$v1_minor" -lt "$v2_minor" ] 2>/dev/null; then
        return 1
    fi
    
    if [ "$v1_patch" -gt "$v2_patch" ] 2>/dev/null; then
        return 0
    elif [ "$v1_patch" -lt "$v2_patch" ] 2>/dev/null; then
        return 1
    fi
    
    return 2
}

# Lấy danh sách phiên bản từ GitHub Releases
# Sort theo created_at (thời gian release) - chính xác nhất
# Chỉ lấy bản stable (x.y.z), bỏ qua -exp, -rc, -beta
fetch_n8n_versions() {
    local limit="${1:-100}"
    
    echo -e "${CYAN}🔍 Đang lấy danh sách phiên bản từ GitHub...${NC}" >&2
    
    # Lấy tag_name bắt đầu bằng n8n@ và created_at, sort theo created_at giảm dần
    # Filter: chỉ lấy version dạng x.y.z (không có -exp, -rc, -beta)
    local versions=$(curl -L -s --connect-timeout 15 "https://api.github.com/repos/n8n-io/n8n/releases?per_page=${limit}" | \
        jq -r '.[] | select(.tag_name | startswith("n8n@")) | "\(.created_at) \(.tag_name)"' 2>/dev/null | \
        sort -r | \
        awk '{print $2}' | \
        sed 's/n8n@//g' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+$')
    
    if [ -z "$versions" ]; then
        echo -e "${RED}❌ Không thể lấy danh sách phiên bản từ GitHub${NC}" >&2
        return 1
    fi
    
    echo "$versions"
}

# Lấy phiên bản mới nhất từ GitHub (release mới nhất theo thời gian)
# Chỉ lấy bản stable (x.y.z)
get_latest_n8n_version() {
    curl -L -s --connect-timeout 15 "https://api.github.com/repos/n8n-io/n8n/releases?per_page=50" | \
        jq -r '.[] | select(.tag_name | startswith("n8n@")) | "\(.created_at) \(.tag_name)"' 2>/dev/null | \
        sort -r | \
        awk '{print $2}' | \
        sed 's/n8n@//g' | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | \
        head -1
}


# Lọc phiên bản: N mới hơn + hiện tại + N cũ hơn
# all_versions đã được sort giảm dần theo thời gian (mới nhất ở trên)
filter_versions_around() {
    local current_version="$1"
    local all_versions="$2"
    local older_count="${3:-4}"
    local newer_count="${4:-4}"
    
    # Tạo file tạm để xử lý
    local tmp_newer="/tmp/n8n_newer_$$"
    local tmp_older="/tmp/n8n_older_$$"
    > "$tmp_newer"
    > "$tmp_older"
    
    local found_current=false
    
    # Duyệt qua danh sách (đã sort theo thời gian: mới nhất -> cũ nhất)
    while IFS= read -r version; do
        [ -z "$version" ] && continue
        
        if [ "$version" = "$current_version" ]; then
            found_current=true
            continue
        fi
        
        if [ "$found_current" = false ]; then
            # Chưa gặp current -> version mới hơn (theo thời gian)
            echo "$version" >> "$tmp_newer"
        else
            # Đã gặp current -> version cũ hơn (theo thời gian)
            echo "$version" >> "$tmp_older"
        fi
    done <<< "$all_versions"
    
    # Nếu không tìm thấy current trong danh sách (version quá cũ)
    # -> Tất cả versions đều mới hơn, lấy N versions mới nhất
    if [ "$found_current" = false ]; then
        local all_as_newer=$(cat "$tmp_newer")
        rm -f "$tmp_newer" "$tmp_older"
        
        # Lấy newer_count versions mới nhất + current
        echo "$all_as_newer" | head -n "$newer_count"
        echo "$current_version"
        return
    fi
    
    # newer đang chứa từ mới nhất -> gần current
    # Lấy N phiên bản gần current nhất (cuối file), giữ thứ tự mới->cũ
    local newer=$(tail -n "$newer_count" "$tmp_newer")
    
    # older đang chứa từ gần current -> cũ nhất  
    # Lấy N phiên bản gần current nhất (đầu file)
    local older=$(head -n "$older_count" "$tmp_older")
    
    # Cleanup
    rm -f "$tmp_newer" "$tmp_older"
    
    # Kết hợp: newer + current + older (tất cả từ mới -> cũ)
    [ -n "$newer" ] && echo "$newer"
    echo "$current_version"
    [ -n "$older" ] && echo "$older"
}

# Hiển thị thông tin phiên bản hiện tại
show_current_version_info() {
    local container="${1:-n8n}"
    
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                        📋 THÔNG TIN PHIÊN BẢN N8N                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    if ! docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
        echo -e "${RED}❌ Container '$container' không đang chạy${NC}"
        return 1
    fi
    
    local current_version=$(get_current_n8n_version "$container")
    local image_info=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
    local created=$(docker inspect --format='{{.Created}}' "$container" 2>/dev/null | cut -d'T' -f1)
    
    echo -e "${WHITE}📦 Container:        ${CYAN}$container${NC}"
    echo -e "${WHITE}🏷️  Phiên bản:        ${GREEN}${current_version:-"Không xác định"}${NC}"
    echo -e "${WHITE}🐳 Docker Image:     ${CYAN}$image_info${NC}"
    echo -e "${WHITE}📅 Ngày tạo:         ${CYAN}$created${NC}"
    
    echo -e "\n${CYAN}🔍 Đang kiểm tra phiên bản mới nhất...${NC}"
    local latest_version=$(get_latest_n8n_version)
    
    if [ -n "$latest_version" ]; then
        echo -e "${WHITE}🆕 Phiên bản mới nhất: ${GREEN}$latest_version${NC}"
        
        if [ -n "$current_version" ]; then
            compare_versions "$latest_version" "$current_version"
            local cmp=$?
            
            if [ $cmp -eq 0 ]; then
                echo -e "${YELLOW}⬆️  Có phiên bản mới hơn available!${NC}"
            elif [ $cmp -eq 2 ]; then
                echo -e "${GREEN}✅ Đang sử dụng phiên bản mới nhất${NC}"
            else
                echo -e "${PURPLE}🔮 Đang sử dụng phiên bản mới hơn bản stable${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}⚠️  Không thể kiểm tra phiên bản mới nhất${NC}"
    fi
}

# Hiển thị danh sách phiên bản
show_version_list() {
    local current_version="$1"
    local show_all="${2:-false}"
    
    echo -e "\n${BOLD}${CYAN}📋 DANH SÁCH PHIÊN BẢN N8N${NC}\n"
    
    local all_versions=$(fetch_n8n_versions 100)
    
    if [ -z "$all_versions" ]; then
        echo -e "${RED}❌ Không thể lấy danh sách phiên bản${NC}"
        return 1
    fi
    
    local versions_to_show=""
    
    if [ "$show_all" = "true" ]; then
        versions_to_show="$all_versions"
    else
        # 5 phiên bản cũ hơn, 5 phiên bản mới hơn
        versions_to_show=$(filter_versions_around "$current_version" "$all_versions" 5 5)
    fi
    
    local total=$(echo "$all_versions" | grep -c '^[0-9]')
    local showing=$(echo "$versions_to_show" | grep -c '^[0-9]')
    
    echo -e "${CYAN}Hiển thị $showing/$total phiên bản${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    
    local index=1
    while IFS= read -r version; do
        [ -z "$version" ] && continue
        
        if [ "$version" = "$current_version" ]; then
            echo -e "  ${BOLD}${index}.${NC} ${GREEN}${version}${NC}         ${GREEN}<< HIEN TAI${NC}"
        else
            compare_versions "$version" "$current_version"
            local cmp=$?
            if [ $cmp -eq 0 ]; then
                echo -e "  ${BOLD}${index}.${NC} ${CYAN}${version}${NC}"
            else
                echo -e "  ${BOLD}${index}.${NC} ${YELLOW}${version}${NC}"
            fi
        fi
        ((index++))
    done <<< "$versions_to_show"
    
    echo ""
    
    # Lưu danh sách để chọn
    echo "$versions_to_show" > /tmp/n8n_version_list.tmp
}


# Menu chọn phiên bản
select_version_interactive() {
    local container="${1:-n8n}"
    local data_dir="${2:-$N8N_DATA_DIR}"
    
    local current_version=$(get_current_n8n_version "$container")
    
    if [ -z "$current_version" ]; then
        echo -e "${RED}❌ Không thể xác định phiên bản hiện tại${NC}"
        return 1
    fi
    
    while true; do
        clear
        print_banner 2>/dev/null || true
        
        echo -e "${BOLD}${CYAN}"
        echo "╔══════════════════════════════════════════════════════════════════════════════╗"
        echo "║                      🔄 QUẢN LÝ PHIÊN BẢN N8N                                ║"
        echo "╚══════════════════════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        
        echo -e "${WHITE}📦 Container: ${CYAN}$container${NC}"
        echo -e "${WHITE}🏷️  Phiên bản hiện tại: ${GREEN}$current_version${NC}"
        echo ""
        
        show_version_list "$current_version" "false"
        
        echo -e "${BOLD}${YELLOW}TÙY CHỌN:${NC}"
        echo -e "  ${BOLD}${GREEN}[số]${NC}  - Chọn phiên bản theo số thứ tự"
        echo -e "  ${BOLD}${CYAN}[a]${NC}   - Xem tất cả phiên bản"
        echo -e "  ${BOLD}${PURPLE}[v]${NC}   - Nhập phiên bản cụ thể (vd: 1.70.0)"
        echo -e "  ${BOLD}${RED}[0]${NC}   - Quay lại"
        echo ""
        
        read -p "$(echo -e "${BOLD}${CYAN}Chọn: ${NC}")" choice
        
        case "$choice" in
            0|q|Q)
                return 0
                ;;
            a|A)
                clear
                print_banner 2>/dev/null || true
                echo -e "${BOLD}${CYAN}📋 TẤT CẢ PHIÊN BẢN N8N${NC}\n"
                show_version_list "$current_version" "true"
                read -p "$(echo -e "${YELLOW}Nhấn Enter để tiếp tục...${NC}")"
                ;;
            v|V)
                read -p "$(echo -e "${CYAN}Nhập phiên bản (vd: 1.70.0): ${NC}")" manual_version
                if [[ "$manual_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    confirm_and_change_version "$container" "$data_dir" "$current_version" "$manual_version"
                    if [ $? -eq 0 ]; then
                        current_version="$manual_version"
                    fi
                else
                    echo -e "${RED}❌ Định dạng phiên bản không hợp lệ${NC}"
                    sleep 2
                fi
                ;;
            [0-9]|[0-9][0-9])
                if [ -f /tmp/n8n_version_list.tmp ]; then
                    local selected_version=$(sed -n "${choice}p" /tmp/n8n_version_list.tmp | tr -d ' \r\n')
                    if [ -n "$selected_version" ]; then
                        confirm_and_change_version "$container" "$data_dir" "$current_version" "$selected_version"
                        if [ $? -eq 0 ]; then
                            current_version="$selected_version"
                        fi
                    else
                        echo -e "${RED}❌ Số thứ tự không hợp lệ${NC}"
                        sleep 2
                    fi
                fi
                ;;
            *)
                echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
                sleep 2
                ;;
        esac
    done
}

# Xác nhận và thay đổi phiên bản
confirm_and_change_version() {
    local container="$1"
    local data_dir="$2"
    local current_version="$3"
    local target_version="$4"
    
    if [ "$current_version" = "$target_version" ]; then
        echo -e "${YELLOW}⚠️  Đã đang sử dụng phiên bản $target_version${NC}"
        sleep 2
        return 1
    fi
    
    local action_type=""
    local action_color=""
    compare_versions "$target_version" "$current_version"
    local cmp=$?
    
    if [ $cmp -eq 0 ]; then
        action_type="NÂNG CẤP"
        action_color="${GREEN}"
    else
        action_type="HẠ CẤP"
        action_color="${YELLOW}"
    fi
    
    echo ""
    echo -e "${BOLD}${action_color}"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                         ⚠️  XÁC NHẬN $action_type                            "
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${WHITE}📦 Container:         ${CYAN}$container${NC}"
    echo -e "${WHITE}🏷️  Phiên bản hiện tại: ${YELLOW}$current_version${NC}"
    echo -e "${WHITE}🎯 Phiên bản đích:     ${action_color}$target_version${NC}"
    echo -e "${WHITE}📁 Thư mục dữ liệu:    ${CYAN}$data_dir${NC}"
    echo ""
    
    if [ "$action_type" = "HẠ CẤP" ]; then
        echo -e "${BOLD}${RED}⚠️  CẢNH BÁO:${NC}"
        echo -e "${YELLOW}   • Hạ cấp có thể gây ra vấn đề tương thích database${NC}"
        echo -e "${YELLOW}   • Một số workflow có thể không hoạt động đúng${NC}"
        echo -e "${YELLOW}   • Khuyến nghị backup trước khi thực hiện${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}💡 Quá trình sẽ:${NC}"
    echo -e "   1. Tạo backup dữ liệu (nếu có module backup)"
    echo -e "   2. Cập nhật docker-compose.yml với phiên bản mới"
    echo -e "   3. Pull image mới và restart container"
    echo ""
    
    while true; do
        read -p "$(echo -e "${BOLD}${YELLOW}Xác nhận thực hiện $action_type? [Y/n]: ${NC}")" confirm
        confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
        
        # Enter mặc định = Y (đồng ý)
        if [ "$confirm" = "y" ] || [ "$confirm" = "yes" ] || [ -z "$confirm" ]; then
            break
        elif [ "$confirm" = "n" ] || [ "$confirm" = "no" ]; then
            echo -e "${YELLOW}❌ Đã hủy thao tác${NC}"
            sleep 1
            return 1
        else
            echo -e "${RED}Vui lòng nhập y hoặc n${NC}"
        fi
    done
    
    change_n8n_version "$container" "$data_dir" "$target_version"
    local result=$?
    
    if [ $result -eq 0 ]; then
        echo ""
        read -p "$(echo -e "${YELLOW}Nhấn Enter để tiếp tục...${NC}")"
    fi
    
    return $result
}


# Thực hiện thay đổi phiên bản n8n
change_n8n_version() {
    local container="$1"
    local data_dir="$2"
    local target_version="$3"
    local compose_file="$data_dir/docker-compose.yml"
    
    echo -e "\n${BOLD}${CYAN}🚀 BẮT ĐẦU THAY ĐỔI PHIÊN BẢN...${NC}\n"
    
    # Bước 1: Kiểm tra file docker-compose.yml
    echo -e "${CYAN}📋 Bước 1/5: Kiểm tra cấu hình...${NC}"
    if [ ! -f "$compose_file" ]; then
        echo -e "${RED}❌ Không tìm thấy file: $compose_file${NC}"
        return 1
    fi
    echo -e "${GREEN}   ✅ Tìm thấy docker-compose.yml${NC}"
    
    # Bước 2: Backup
    echo -e "\n${CYAN}💾 Bước 2/5: Tạo backup...${NC}"
    if type create_manual_backup &>/dev/null; then
        create_manual_backup 2>/dev/null
        echo -e "${GREEN}   ✅ Đã tạo backup${NC}"
    else
        echo -e "${YELLOW}   ⚠️  Module backup không khả dụng, bỏ qua${NC}"
    fi
    
    # Bước 3: Backup docker-compose.yml
    echo -e "\n${CYAN}📦 Bước 3/5: Backup docker-compose.yml...${NC}"
    local backup_compose="${compose_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$compose_file" "$backup_compose"
    echo -e "${GREEN}   ✅ Đã backup: $backup_compose${NC}"
    
    # Bước 4: Cập nhật docker-compose.yml
    echo -e "\n${CYAN}📝 Bước 4/5: Cập nhật phiên bản trong docker-compose.yml...${NC}"
    
    if sed -i "s|image: n8nio/n8n:.*|image: n8nio/n8n:${target_version}|g" "$compose_file"; then
        echo -e "${GREEN}   ✅ Đã cập nhật image tag thành n8nio/n8n:${target_version}${NC}"
    else
        echo -e "${RED}   ❌ Lỗi khi cập nhật docker-compose.yml${NC}"
        echo -e "${YELLOW}   🔄 Đang rollback...${NC}"
        cp "$backup_compose" "$compose_file"
        return 1
    fi
    
    # Bước 5: Pull image và restart
    echo -e "\n${CYAN}🐳 Bước 5/5: Pull image và restart container...${NC}"
    
    cd "$data_dir" || {
        echo -e "${RED}❌ Không thể chuyển đến thư mục $data_dir${NC}"
        return 1
    }
    
    echo -e "${CYAN}   📥 Đang pull image n8nio/n8n:${target_version}...${NC}"
    if docker-compose pull n8n 2>&1 | while read line; do echo -e "      $line"; done; then
        echo -e "${GREEN}   ✅ Đã pull image thành công${NC}"
    else
        echo -e "${RED}   ❌ Lỗi khi pull image${NC}"
        echo -e "${YELLOW}   🔄 Đang rollback...${NC}"
        cp "$backup_compose" "$compose_file"
        return 1
    fi
    
    echo -e "${CYAN}   🔄 Đang restart container...${NC}"
    if docker-compose up -d n8n 2>&1 | while read line; do echo -e "      $line"; done; then
        echo -e "${GREEN}   ✅ Đã restart container${NC}"
    else
        echo -e "${RED}   ❌ Lỗi khi restart container${NC}"
        return 1
    fi
    
    # Đợi container khởi động
    echo -e "\n${CYAN}⏳ Đang đợi n8n khởi động...${NC}"
    local retry=0
    local max_retry=12
    
    while [ $retry -lt $max_retry ]; do
        sleep 5
        if docker exec "$container" n8n --version &>/dev/null; then
            break
        fi
        ((retry++))
        echo -e "${CYAN}   ⏳ Đang đợi... ($retry/$max_retry)${NC}"
    done
    
    # Kiểm tra kết quả
    local new_version=$(get_current_n8n_version "$container")
    
    echo ""
    if [ "$new_version" = "$target_version" ]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                    ✅ THAY ĐỔI PHIÊN BẢN THÀNH CÔNG!                         ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${WHITE}🏷️  Phiên bản mới: ${GREEN}$new_version${NC}"
        
        log_message "SUCCESS" "Đã thay đổi n8n từ phiên bản cũ sang $target_version" 2>/dev/null
        return 0
    else
        echo -e "${YELLOW}⚠️  Phiên bản sau khi restart: ${new_version:-"Không xác định"}${NC}"
        echo -e "${YELLOW}   Có thể cần thêm thời gian để container khởi động hoàn tất${NC}"
        return 0
    fi
}

# Menu quản lý phiên bản (entry point)
handle_version_menu() {
    local container="${SELECTED_CONTAINER:-n8n}"
    local data_dir="${SELECTED_DATA_DIR:-$N8N_DATA_DIR}"
    
    # Chọn instance nếu có nhiều instance
    if type select_instance_for_operation &>/dev/null; then
        if ! select_instance_for_operation "Chọn instance để quản lý phiên bản"; then
            return 0
        fi
        container="${SELECTED_CONTAINER:-n8n}"
        data_dir="${SELECTED_DATA_DIR:-$N8N_DATA_DIR}"
    fi
    
    while true; do
        clear
        print_banner 2>/dev/null || true
        
        echo -e "${BOLD}${CYAN}"
        echo "╔══════════════════════════════════════════════════════════════════════════════╗"
        echo "║                      🔄 QUẢN LÝ PHIÊN BẢN N8N                                ║"
        echo "╚══════════════════════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        
        echo -e "  ${BOLD}${GREEN}1.${NC} ${WHITE}Xem thông tin phiên bản hiện tại${NC}"
        echo -e "  ${BOLD}${CYAN}2.${NC} ${WHITE}Chọn phiên bản để cài đặt${NC}"
        echo -e "  ${BOLD}${PURPLE}3.${NC} ${WHITE}Cập nhật lên phiên bản mới nhất${NC}"
        echo ""
        echo -e "  ${BOLD}${RED}0.${NC} ${WHITE}Quay lại${NC}"
        echo ""
        
        read -p "$(echo -e "${BOLD}${CYAN}Chọn [0-3]: ${NC}")" choice
        
        case $choice in
            1)
                echo ""
                show_current_version_info "$container"
                echo ""
                read -p "$(echo -e "${YELLOW}Nhấn Enter để tiếp tục...${NC}")"
                ;;
            2)
                select_version_interactive "$container" "$data_dir"
                ;;
            3)
                echo ""
                local current=$(get_current_n8n_version "$container")
                local latest=$(get_latest_n8n_version)
                
                if [ -n "$latest" ] && [ -n "$current" ]; then
                    compare_versions "$latest" "$current"
                    if [ $? -eq 0 ]; then
                        confirm_and_change_version "$container" "$data_dir" "$current" "$latest"
                    else
                        echo -e "${GREEN}✅ Đã đang sử dụng phiên bản mới nhất ($current)${NC}"
                        sleep 2
                    fi
                else
                    echo -e "${RED}❌ Không thể kiểm tra phiên bản${NC}"
                    sleep 2
                fi
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}❌ Lựa chọn không hợp lệ${NC}"
                sleep 1
                ;;
        esac
    done
}
