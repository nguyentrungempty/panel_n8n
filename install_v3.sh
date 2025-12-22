#!/usr/bin/env bash

# Script cài đặt N8N Panel v3 vào /opt/n8npanel/v3

set -e

readonly GREEN='\033[0;32m'
readonly CYAN='\033[0;36m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

INSTALL_DIR="/opt/n8npanel/v3"
MANIFEST_URL="https://raw.githubusercontent.com/nguyentrungempty/panel_n8n/refs/heads/main/manifest.json/manifest.json"

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║         N8N PANEL V3 - INSTALLATION SCRIPT                   ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Script này cần quyền root${NC}"
    echo -e "${YELLOW}💡 Chạy lại với: sudo $0${NC}"
    exit 1
fi

echo -e "${CYAN}📁 Bước 1/5: Tạo thư mục cài đặt...${NC}"
mkdir -p "$INSTALL_DIR"
echo -e "${GREEN}✅ Đã tạo: $INSTALL_DIR${NC}"

echo -e "\n${CYAN}📥 Bước 2/5: Tạo cấu trúc thư mục...${NC}"

# Tạo tất cả thư mục cần thiết
directories=("common" "1_Cai_dat_n8n_moi" "2_Quan_ly_Backup" "3_Quan_ly_SSL" "4_Quan_ly_Docker_Container" "5_Quan_ly_N8N" "6_Xem_thong_tin_he_thong" "7_Cap_nhat" "8_Multi_Instance" "9_Go_cai_dat")

for dir in "${directories[@]}"; do
    mkdir -p "$INSTALL_DIR/$dir"
    echo -e "${GREEN}  ✅ Tạo thư mục: $dir${NC}"
done

echo -e "\n${CYAN}📥 Bước 3/5: Tải tất cả file...${NC}"

# Danh sách file cần tải (hardcode để đảm bảo)
files=(
    "manifest.json"
    "n8n.sh"
    "hook.py"
    "STRUCTURE.txt"
    "common/utils.sh"
    "common/network.sh"
    "common/nginx_manager.sh"
    "common/ssl_manager.sh"
    "common/env_manager.sh"
    "common/domain_manager.sh"
    "common/restart_manager.sh"
    "common/instance_selector.sh"
    "common/domain_change_wrapper.sh"
    "common/nginx_config_wrapper.sh"
    "common/ssl_install_wrapper.sh"
    "1_Cai_dat_n8n_moi/install.sh"
    "2_Quan_ly_Backup/backup.sh"
    "3_Quan_ly_SSL/ssl.sh"
    "4_Quan_ly_Docker_Container/docker.sh"
    "5_Quan_ly_N8N/manage.sh"
    "6_Xem_thong_tin_he_thong/system_info.sh"
    "7_Cap_nhat/update.sh"
    "7_Cap_nhat/version_manager.sh"
    "8_Multi_Instance/multi_instance.sh"
    "9_Go_cai_dat/uninstall.sh"
)

total_files=${#files[@]}
current=0

for file in "${files[@]}"; do
    current=$((current + 1))
    echo -e "${CYAN}  [$current/$total_files] Đang tải: $file${NC}"
    
    # Xác định đích đến cho file
    dest_path="$INSTALL_DIR/$file"
    
    # Hook.py đặc biệt: tải về /opt/n8n/ thay vì /opt/n8npanel/v3/
    if [ "$file" = "hook.py" ]; then
        dest_path="/opt/n8n/hook.py"
        mkdir -p "/opt/n8n"
        echo -e "${YELLOW}     📍 Đích đến đặc biệt: /opt/n8n/hook.py${NC}"
    else
        # Tạo thư mục cha nếu file nằm trong thư mục con
        file_dir=$(dirname "$dest_path")
        if [ "$file_dir" != "$INSTALL_DIR" ]; then
            mkdir -p "$file_dir"
        fi
    fi
    
    # Retry 3 lần
    success=false
    for attempt in {1..3}; do
        if curl -s --connect-timeout 30 "https://raw.githubusercontent.com/nguyentrungempty/panel_n8n/refs/heads/main/manifest.json/$file" -o "$dest_path" 2>/dev/null; then
            # Kiểm tra file có hợp lệ không (không phải HTML)
            if head -n 1 "$dest_path" 2>/dev/null | grep -q "^#!" || [[ "$file" == *.json ]] || [[ "$file" == *.txt ]] || [[ "$file" == *.py ]]; then
                chmod +x "$dest_path" 2>/dev/null
                echo -e "${GREEN}     ✅ Thành công${NC}"
                success=true
                break
            else
                echo -e "${YELLOW}     ⚠️  File không hợp lệ (có thể là HTML), thử lại... ($attempt/3)${NC}"
                rm -f "$dest_path"
                sleep 1
            fi
        else
            echo -e "${YELLOW}     ⚠️  Lỗi tải, thử lại... ($attempt/3)${NC}"
            sleep 1
        fi
    done
    
    if [ "$success" = false ]; then
        echo -e "${RED}     ❌ THẤT BẠI sau 3 lần thử: $file${NC}"
        echo -e "${RED}     💡 Kiểm tra URL: https://raw.githubusercontent.com/nguyentrungempty/panel_n8n/refs/heads/main/manifest.json/$file${NC}"
    fi
done

echo -e "\n${CYAN}🔧 Bước 4/5: Kiểm tra và cấp quyền...${NC}"

# Đếm số file thành công
downloaded_count=$(find "$INSTALL_DIR" -name "*.sh" -type f | wc -l)
echo -e "${GREEN}✅ Đã tải thành công: $downloaded_count file .sh${NC}"

# Cấp quyền thực thi
find "$INSTALL_DIR" -name "*.sh" -type f -exec chmod +x {} \;
echo -e "${GREEN}✅ Đã cấp quyền thực thi${NC}"

# Cảnh báo nếu thiếu file
if [ $downloaded_count -lt 11 ]; then
    echo -e "${RED}⚠️  CẢNH BÁO: Một số file không tải được!${NC}"
    echo -e "${YELLOW}💡 Kiểm tra lại URL hoặc chạy lại script${NC}"
fi

echo -e "\n${CYAN}🔗 Bước 5/5: Tạo symlink...${NC}"
if [ -f "/usr/local/bin/n8n" ] || [ -L "/usr/local/bin/n8n" ]; then
    echo -e "${YELLOW}⚠️  /usr/local/bin/n8n đã tồn tại, đang ghi đè...${NC}"
    rm -f /usr/local/bin/n8n
fi

ln -sf "$INSTALL_DIR/n8n.sh" /usr/local/bin/n8n
echo -e "${GREEN}✅ Đã tạo symlink: /usr/local/bin/n8n → $INSTALL_DIR/n8n.sh${NC}"

echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ CÀI ĐẶT HOÀN TẤT! ✅                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${CYAN}📋 Thông tin cài đặt:${NC}"
echo -e "${GREEN}  • Thư mục panel: ${BOLD}$INSTALL_DIR${NC}"
echo -e "${GREEN}  • Symlink: ${BOLD}/usr/local/bin/n8n${NC}"
echo -e "${GREEN}  • Data directory: ${BOLD}/root/n8n_data${NC}"

# Đọc version từ manifest nếu có
if [ -f "$INSTALL_DIR/manifest.json" ]; then
    if command -v jq >/dev/null 2>&1; then
        version=$(jq -r '.version' "$INSTALL_DIR/manifest.json" 2>/dev/null || echo "3.0")
    else
        version="3.0"
    fi
else
    version="3.0"
fi
echo -e "${GREEN}  • Phiên bản: ${BOLD}v$version${NC}"

# Kiểm tra hook.py
if [ -f "/opt/n8n/hook.py" ]; then
    hook_version=$(grep "^HOOK_VERSION = " "/opt/n8n/hook.py" 2>/dev/null | cut -d'"' -f2)
    echo -e "${GREEN}  • Webhook hook: ${BOLD}/opt/n8n/hook.py (v${hook_version:-3.0})${NC}"
else
    echo -e "${YELLOW}  • Webhook hook: ${BOLD}Không tải được${NC}"
fi

echo -e "\n${CYAN}🚀 Chạy panel:${NC}"
echo -e "${YELLOW}  n8n${NC}"

echo -e "\n${CYAN}💡 Hoặc:${NC}"
echo -e "${YELLOW}  $INSTALL_DIR/n8n.sh${NC}"

echo -e "\n${CYAN}🔗 Chạy webhook service (nếu cần):${NC}"
echo -e "${YELLOW}  python3 /opt/n8n/hook.py 8888${NC}"
